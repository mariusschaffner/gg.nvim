--- Merge request reviews: reviewers and approvals, draft notes, publishing
--- a review, approving.
---
--- Backends:
---   * reviewers: GraphQL (`reviewers` with `mergeRequestInteraction`, and
---     `approvedBy`).
---   * draft notes, bulk publish, approve: REST (`/draft_notes`,
---     `/draft_notes/bulk_publish`, `/approve`); GraphQL has no draft notes API.
local common = require("gg.resources.common")
local errors = require("gg.core.errors")
local graphql = require("gg.graphql.client")
local rest = require("gg.rest.client")
local review_model = require("gg.models.review")
local task = require("gg.core.task")

local M = {}

M.DRAFTS_PER_PAGE = 100

local MR_SPEC = { host = "host", project = "project", iid = "id" }

local function spec(extra)
  local s = vim.deepcopy(MR_SPEC)
  for k, v in pairs(extra or {}) do
    s[k] = v
  end
  return s
end

local function mr_path(args, suffix)
  return ("/projects/%s/merge_requests/%d%s"):format(rest.project(args.project), common.int(args.iid), suffix or "")
end

--- Reviewers with their review state; approvers who are not reviewers are
--- included as participants.
---@param args { host: string, project: string|integer, iid: integer }
---@return gg.Task resolves with { reviewers: gg.Reviewer[], truncated: gg.Truncated|nil }
function M.reviewers(args)
  return common.run(args, MR_SPEC, function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local data, err = graphql.query(args.host, "mr_reviewers", { fullPath = path, iid = tostring(args.iid) }):await()
    if err then
      return nil, err
    end
    local node, nerr = graphql.require(data, "project.mergeRequest", ("merge request %s!%d"):format(path, common.int(args.iid)))
    if not node then
      return nil, nerr
    end
    local list, truncated = review_model.reviewers_from_graphql(node, { origin = common.origin(args.host) })
    return { reviewers = list, truncated = truncated }
  end)
end

local function drafts_fetch(args, o)
  local err = common.check(args, MR_SPEC)
  if err then
    return task.failed(err)
  end
  return task.run(function()
    local page, rerr = rest.page(args.host, mr_path(args, "/draft_notes"), {
      per_page = o.per_page,
      default_per_page = M.DRAFTS_PER_PAGE,
      cursor = o.cursor,
    }):await()
    if not page then
      return nil, rerr
    end
    return { items = vim.tbl_map(review_model.draft_from_rest, page.items), next_cursor = page.next_cursor }
  end)
end

local drafts, drafts_all = common.lists(drafts_fetch)

--- One page of the current user's pending draft notes. Resolves with `gg.Page<gg.DraftNote>`.
---@param args { host: string, project: string|integer, iid: integer }
---@param opts? { per_page?: integer, cursor?: string }
---@return gg.Task
function M.drafts(args, opts)
  return drafts(args, opts)
end

--- All pending draft notes up to `opts.limit`.
---@param args { host: string, project: string|integer, iid: integer }
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.DraftNote[]) }
---@return gg.Task resolves with { items: gg.DraftNote[], truncated: boolean }
function M.drafts_all(args, opts)
  return drafts_all(args, opts)
end

---@class gg.DraftCreateArgs
---@field host string
---@field project string|integer
---@field iid integer
---@field note string
---@field position? table a diff position (as for gg.notes.add, with all SHAs)
---@field in_reply_to_discussion_id? string
---@field resolve_discussion? boolean
---@field commit_id? string

--- Create a draft note (a pending review comment).
---@param args gg.DraftCreateArgs
---@return gg.Task resolves with gg.DraftNote
function M.create_draft(args)
  local s = spec({ note = "string", position = "table?", in_reply_to_discussion_id = "string?", resolve_discussion = "boolean?", commit_id = "string?" })
  return common.run(args, s, function()
    local res, err = rest.request(args.host, "POST", mr_path(args, "/draft_notes"), {
      body = {
        note = args.note,
        position = args.position,
        in_reply_to_discussion_id = args.in_reply_to_discussion_id,
        resolve_discussion = args.resolve_discussion,
        commit_id = args.commit_id,
      },
    }):await()
    if err then
      return nil, err
    end
    return review_model.draft_from_rest(res.data)
  end)
end

--- Edit a draft note.
---@param args { host: string, project: string|integer, iid: integer, draft_id: integer, note?: string, position?: table }
---@return gg.Task resolves with gg.DraftNote
function M.edit_draft(args)
  local s = spec({ draft_id = "id", note = "string?", position = "table?" })
  local err = common.check(args, s)
  if err then
    return task.failed(err)
  end
  if args.note == nil and args.position == nil then
    return task.failed(common.invalid("note", "(or args.position) is required: nothing to update"))
  end
  return task.run(function()
    local path = mr_path(args, ("/draft_notes/%d"):format(common.int(args.draft_id)))
    local res, rerr = rest.request(args.host, "PUT", path, { body = { note = args.note, position = args.position } }):await()
    if rerr then
      return nil, rerr
    end
    return review_model.draft_from_rest(res.data)
  end)
end

local function delete_draft(args, id)
  return rest.request(args.host, "DELETE", mr_path(args, ("/draft_notes/%d"):format(common.int(id))))
end

--- Delete a draft note. Resolves with `true`.
---@param args { host: string, project: string|integer, iid: integer, draft_id: integer }
---@return gg.Task
function M.delete_draft(args)
  return common.run(args, spec({ draft_id = "id" }), function()
    local _, err = delete_draft(args, args.draft_id):await()
    if err then
      return nil, err
    end
    return true
  end)
end

--- Discard pending drafts: collect up to `opts.limit` and delete them one
--- after another. Stops at the first error; `err.details.deleted` says how
--- many were deleted before it.
---@param args { host: string, project: string|integer, iid: integer }
---@param opts { limit: integer }
---@return gg.Task resolves with { deleted: integer, truncated: boolean }
function M.discard_drafts(args, opts)
  local err = common.check(args, MR_SPEC)
  if err then
    return task.failed(err)
  end
  return task.run(function()
    local res, lerr = drafts_all(args, opts):await()
    if not res then
      return nil, lerr
    end
    local deleted = 0
    for _, d in ipairs(res.items) do
      local _, derr = delete_draft(args, d.id):await()
      if derr then
        return nil, errors.new(derr.kind, derr.message, {
          status = derr.status,
          details = vim.tbl_extend("force", derr.details or {}, { deleted = deleted, draft_id = d.id }),
        })
      end
      deleted = deleted + 1
    end
    return { deleted = deleted, truncated = res.truncated }
  end)
end

--- Publish all pending drafts, with an optional summary note and review
--- state ("reviewed" or "requested_changes"; approving is `approve`).
---@param args { host: string, project: string|integer, iid: integer, note?: string, reviewer_state?: "reviewed"|"requested_changes", internal?: boolean }
---@return gg.Task resolves with `true`
function M.publish(args)
  local s = spec({ note = "string?", reviewer_state = common.enum(true, "reviewed", "requested_changes"), internal = "boolean?" })
  return common.run(args, s, function()
    local body = { note = args.note, reviewer_state = args.reviewer_state, internal = args.internal }
    if next(body) == nil then
      body = vim.empty_dict()
    end
    local _, err = rest.request(args.host, "POST", mr_path(args, "/draft_notes/bulk_publish"), { body = body }):await()
    if err then
      return nil, err
    end
    return true
  end)
end

--- Approve a merge request. With `sha`, GitLab refuses (409, `validation`)
--- when the source branch moved on.
---@param args { host: string, project: string|integer, iid: integer, sha?: string }
---@return gg.Task resolves with { approvals_required: integer|nil, approvals_left: integer|nil }
function M.approve(args)
  return common.run(args, spec({ sha = "string?" }), function()
    local body = args.sha and { sha = args.sha } or vim.empty_dict()
    local res, err = rest.request(args.host, "POST", mr_path(args, "/approve"), { body = body }):await()
    if err then
      return nil, err
    end
    local d = res.data or {}
    return { approvals_required = tonumber(d.approvals_required), approvals_left = tonumber(d.approvals_left) }
  end)
end

return M
