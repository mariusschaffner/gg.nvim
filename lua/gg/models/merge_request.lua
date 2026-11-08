--- Merge request model. Pure.
---
--- Field names follow GitLab's API. `state` and `draft` are independent: a
--- draft merge request is `state = "opened", draft = true`.
local gid = require("gg.models.gid")
local label = require("gg.models.label")
local milestone = require("gg.models.milestone")
local user = require("gg.models.user")
local util = require("gg.models.util")

local M = {}

---@class gg.DiffRefs
---@field base_sha string|nil
---@field head_sha string
---@field start_sha string

---@class gg.MergeRequest
---@field id integer
---@field iid integer
---@field project string|nil full path of the target project
---@field title string
---@field description string|nil only from `get` (and REST responses)
---@field state "opened"|"closed"|"merged"|"locked"
---@field draft boolean
---@field author gg.User|nil
---@field assignees gg.User[]
---@field reviewers gg.User[]
---@field labels gg.Label[]
---@field milestone gg.MilestoneRef|nil
---@field source_branch string
---@field target_branch string
---@field source_project_id integer|nil
---@field target_project_id integer|nil
---@field sha string|nil head commit of the source branch
---@field diff_refs gg.DiffRefs|nil
---@field merge_status string|nil "can_be_merged", "cannot_be_merged", "checking", ...
---@field detailed_merge_status string|nil "mergeable", "not_open", "ci_must_pass", ...
---@field has_conflicts boolean|nil
---@field user_notes_count integer
---@field should_remove_source_branch boolean|nil
---@field force_remove_source_branch boolean|nil
---@field squash boolean|nil
---@field web_url string|nil
---@field references gg.References
---@field created_at string
---@field updated_at string
---@field merged_at string|nil
---@field closed_at string|nil
---@field subscribed boolean|nil only from `get`
---@field truncated gg.Truncated|nil

local function diff_refs_rest(r)
  r = util.value(r)
  if type(r) ~= "table" then
    return nil
  end
  return { base_sha = util.value(r.base_sha), head_sha = util.value(r.head_sha), start_sha = util.value(r.start_sha) }
end

local function diff_refs_graphql(r)
  r = util.value(r)
  if type(r) ~= "table" then
    return nil
  end
  return { base_sha = util.value(r.baseSha), head_sha = util.value(r.headSha), start_sha = util.value(r.startSha) }
end

--- Map a REST merge request.
---@param raw table|nil
---@param ctx? { origin?: string, project?: string }
---@return gg.MergeRequest|nil
function M.from_rest(raw, ctx)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  ctx = ctx or {}
  local refs = util.value(raw.references) or {}
  local full = util.value(refs.full)
  local function users(list)
    return util.map(list, function(u)
      return user.from_rest(u, ctx)
    end)
  end
  local draft = util.value(raw.draft)
  if draft == nil then
    draft = util.value(raw.work_in_progress)
  end
  return {
    id = tonumber(util.value(raw.id)),
    iid = tonumber(util.value(raw.iid)),
    project = util.project_of_reference(full) or ctx.project,
    title = util.value(raw.title),
    description = util.value(raw.description),
    state = util.value(raw.state),
    draft = draft == true,
    author = user.from_rest(raw.author, ctx),
    assignees = users(raw.assignees),
    reviewers = users(raw.reviewers),
    labels = util.map(raw.labels, label.from_rest),
    milestone = milestone.ref_from_rest(raw.milestone),
    source_branch = util.value(raw.source_branch),
    target_branch = util.value(raw.target_branch),
    source_project_id = tonumber(util.value(raw.source_project_id)),
    target_project_id = tonumber(util.value(raw.target_project_id)),
    sha = util.value(raw.sha),
    diff_refs = diff_refs_rest(raw.diff_refs),
    merge_status = util.value(raw.merge_status),
    detailed_merge_status = util.value(raw.detailed_merge_status),
    has_conflicts = util.value(raw.has_conflicts),
    user_notes_count = tonumber(util.value(raw.user_notes_count)) or 0,
    should_remove_source_branch = util.value(raw.should_remove_source_branch),
    force_remove_source_branch = util.value(raw.force_remove_source_branch),
    squash = util.value(raw.squash),
    web_url = util.value(raw.web_url),
    references = { short = util.value(refs.short), full = full },
    created_at = util.value(raw.created_at),
    updated_at = util.value(raw.updated_at),
    merged_at = util.value(raw.merged_at),
    closed_at = util.value(raw.closed_at),
    subscribed = util.value(raw.subscribed),
  }
end

--- Map a GraphQL MergeRequest node (selected with MergeRequestFields).
---@param node table|nil
---@param ctx? { origin?: string, project?: string }
---@return gg.MergeRequest|nil
function M.from_graphql(node, ctx)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  ctx = ctx or {}
  local full = util.value(node.referenceFull)
  local function users(conn)
    return util.map(util.nodes(conn), function(u)
      return user.from_graphql(u, ctx)
    end)
  end
  local truncated
  if util.has_more(node.assignees) or util.has_more(node.reviewers) or util.has_more(node.labels) then
    truncated = {
      assignees = util.has_more(node.assignees) or nil,
      reviewers = util.has_more(node.reviewers) or nil,
      labels = util.has_more(node.labels) or nil,
    }
  end
  return {
    id = gid.tail(util.value(node.id)),
    iid = tonumber(util.value(node.iid)),
    project = util.project_of_reference(full) or ctx.project,
    title = util.value(node.title),
    description = util.value(node.description),
    state = util.value(node.state),
    draft = util.value(node.draft) == true,
    author = user.from_graphql(node.author, ctx),
    assignees = users(node.assignees),
    reviewers = users(node.reviewers),
    labels = util.map(util.nodes(node.labels), label.from_graphql),
    milestone = milestone.ref_from_graphql(node.milestone, ctx),
    source_branch = util.value(node.sourceBranch),
    target_branch = util.value(node.targetBranch),
    source_project_id = tonumber(util.value(node.sourceProjectId)),
    target_project_id = tonumber(util.value(node.targetProjectId)),
    sha = util.value(node.diffHeadSha),
    diff_refs = diff_refs_graphql(node.diffRefs),
    merge_status = util.lower(node.mergeStatusEnum),
    detailed_merge_status = util.lower(node.detailedMergeStatus),
    has_conflicts = util.value(node.conflicts),
    user_notes_count = tonumber(util.value(node.userNotesCount)) or 0,
    should_remove_source_branch = util.value(node.shouldRemoveSourceBranch),
    force_remove_source_branch = util.value(node.forceRemoveSourceBranch),
    squash = util.value(node.squash),
    web_url = util.value(node.webUrl),
    references = { short = util.value(node.reference), full = full },
    created_at = util.value(node.createdAt),
    updated_at = util.value(node.updatedAt),
    merged_at = util.value(node.mergedAt),
    closed_at = util.value(node.closedAt),
    subscribed = util.value(node.subscribed),
    truncated = truncated,
  }
end

return M
