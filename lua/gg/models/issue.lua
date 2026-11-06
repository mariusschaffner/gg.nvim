--- Issue model. Pure.
---
--- GitLab-native field names. Renames from atlas's Issue type:
---   story_points <- weight, status <- state, duedate <- due_date,
---   comment_count <- user_notes_count, reporter <- author,
---   key <- project .. "#" .. iid, url <- web_url.
local gid = require("gg.models.gid")
local label = require("gg.models.label")
local milestone = require("gg.models.milestone")
local user = require("gg.models.user")
local util = require("gg.models.util")

local M = {}

---@class gg.References
---@field short string|nil "#12"
---@field full string|nil "group/repo#12"

---@class gg.Truncated
---@field assignees boolean|nil
---@field labels boolean|nil
---@field reviewers boolean|nil
---@field notes boolean|nil
---@field stages boolean|nil
---@field jobs boolean|nil

---@class gg.Issue
---@field id integer
---@field iid integer
---@field project string|nil full path of the project
---@field title string
---@field description string|nil only from `get` (and REST responses)
---@field state "opened"|"closed"|"locked"
---@field type string "issue", "incident", "test_case", "task", ...
---@field confidential boolean
---@field author gg.User|nil
---@field assignees gg.User[]
---@field labels gg.Label[]
---@field milestone gg.MilestoneRef|nil
---@field weight integer|nil
---@field due_date string|nil YYYY-MM-DD
---@field web_url string
---@field references gg.References
---@field user_notes_count integer
---@field created_at string ISO 8601
---@field updated_at string ISO 8601
---@field closed_at string|nil ISO 8601
---@field subscribed boolean|nil only from `get`
---@field truncated gg.Truncated|nil set when a nested list was cut off

--- Map a REST issue.
---@param raw table|nil
---@param ctx? { origin?: string, project?: string }
---@return gg.Issue|nil
function M.from_rest(raw, ctx)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  ctx = ctx or {}
  local refs = util.value(raw.references) or {}
  local full = util.value(refs.full)
  local assignees = util.value(raw.assignees)
  if assignees == nil and util.value(raw.assignee) then
    assignees = { raw.assignee }
  end
  return {
    id = tonumber(util.value(raw.id)),
    iid = tonumber(util.value(raw.iid)),
    project = util.project_of_reference(full) or ctx.project,
    title = util.value(raw.title),
    description = util.value(raw.description),
    state = util.value(raw.state),
    type = util.lower(raw.issue_type) or util.lower(raw.type) or "issue",
    confidential = util.value(raw.confidential) == true,
    author = user.from_rest(raw.author, ctx),
    assignees = util.map(assignees, function(u)
      return user.from_rest(u, ctx)
    end),
    labels = util.map(raw.labels, label.from_rest),
    milestone = milestone.ref_from_rest(raw.milestone),
    weight = tonumber(util.value(raw.weight)),
    due_date = util.date(raw.due_date),
    web_url = util.value(raw.web_url),
    references = { short = util.value(refs.short), full = full },
    user_notes_count = tonumber(util.value(raw.user_notes_count)) or 0,
    created_at = util.value(raw.created_at),
    updated_at = util.value(raw.updated_at),
    closed_at = util.value(raw.closed_at),
    subscribed = util.value(raw.subscribed),
  }
end

--- Map a GraphQL Issue node (selected with the IssueFields fragment).
---@param node table|nil
---@param ctx? { origin?: string, project?: string }
---@return gg.Issue|nil
function M.from_graphql(node, ctx)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  ctx = ctx or {}
  local full = util.value(node.referenceFull)
  local truncated
  if util.has_more(node.assignees) or util.has_more(node.labels) then
    truncated = { assignees = util.has_more(node.assignees) or nil, labels = util.has_more(node.labels) or nil }
  end
  return {
    id = gid.tail(util.value(node.id)),
    iid = tonumber(util.value(node.iid)),
    project = util.project_of_reference(full) or ctx.project,
    title = util.value(node.title),
    description = util.value(node.description),
    state = util.value(node.state),
    type = util.lower(node.type) or "issue",
    confidential = util.value(node.confidential) == true,
    author = user.from_graphql(node.author, ctx),
    assignees = util.map(util.nodes(node.assignees), function(u)
      return user.from_graphql(u, ctx)
    end),
    labels = util.map(util.nodes(node.labels), label.from_graphql),
    milestone = milestone.ref_from_graphql(node.milestone, ctx),
    weight = tonumber(util.value(node.weight)),
    due_date = util.date(node.dueDate),
    web_url = util.value(node.webUrl),
    references = { short = util.value(node.reference), full = full },
    user_notes_count = tonumber(util.value(node.userNotesCount)) or 0,
    created_at = util.value(node.createdAt),
    updated_at = util.value(node.updatedAt),
    closed_at = util.value(node.closedAt),
    subscribed = util.value(node.subscribed),
    truncated = truncated,
  }
end

return M
