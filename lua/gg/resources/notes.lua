--- Notes and discussions on issues and merge requests (`args.noteable`).
---
--- Backends:
---   * issue discussions, and flat note lists (all / comments / activity):
---     GraphQL (`issue.discussions`, `{issue,mergeRequest}.notes(filter:)`),
---     paginated.
---   * merge request discussions: REST `/merge_requests/:iid/discussions`.
---     GraphQL notes have no original position, which outdated diff threads
---     need.
---   * add, reply, edit, delete: REST discussions/notes API.
---   * set_resolved: REST for merge requests; GraphQL
---     `discussionToggleResolve` for issues (the REST issue thread API cannot
---     resolve).
local common = require("gg.resources.common")
local gid = require("gg.models.gid")
local graphql = require("gg.graphql.client")
local mr_changes = require("gg.resources.mr_changes")
local note_model = require("gg.models.note")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

M.DISCUSSIONS_PER_PAGE = 20
M.NOTES_PER_PAGE = 100

local NOTEABLE = common.enum(false, "issue", "merge_request")
local SEGMENT = { issue = "issues", merge_request = "merge_requests" }
local FILTER = { all = "ALL_NOTES", comments = "ONLY_COMMENTS", activity = "ONLY_ACTIVITY" }

local BASE = { host = "host", project = "project", iid = "id", noteable = NOTEABLE }

local function spec(extra)
  local s = vim.deepcopy(BASE)
  for k, v in pairs(extra or {}) do
    s[k] = v
  end
  return s
end

local function noteable_path(args, suffix)
  return ("/projects/%s/%s/%d%s"):format(rest.project(args.project), SEGMENT[args.noteable], common.int(args.iid), suffix or "")
end

local function what(args, path)
  return ("%s %s%s%d"):format(args.noteable == "issue" and "issue" or "merge request", path, args.noteable == "issue" and "#" or "!", common.int(args.iid))
end

---@class gg.NoteableArgs
---@field host string
---@field project string|integer
---@field iid integer issue or merge request IID
---@field noteable "issue"|"merge_request"

local function discussions_fetch(args, o)
  local err = common.check(args, BASE)
  if err then
    return task.failed(err)
  end
  local origin = common.origin(args.host)
  return task.run(function()
    if args.noteable == "merge_request" then
      local page, rerr = rest.page(args.host, noteable_path(args, "/discussions"), {
        per_page = o.per_page,
        default_per_page = M.DISCUSSIONS_PER_PAGE,
        cursor = o.cursor,
      }):await()
      if not page then
        return nil, rerr
      end
      return {
        items = vim.tbl_map(function(raw)
          return note_model.discussion_from_rest(raw, { origin = origin })
        end, page.items),
        next_cursor = page.next_cursor,
      }
    end
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local page, gerr = graphql.page(args.host, "issue_discussions", { fullPath = path, iid = tostring(args.iid) }, "project.issue.discussions", {
      cursor = o.cursor,
      per_page = o.per_page,
      default_per_page = M.DISCUSSIONS_PER_PAGE,
      what = what(args, path),
    }):await()
    if not page then
      return nil, gerr
    end
    return {
      items = vim.tbl_map(function(n)
        return note_model.discussion_from_graphql(n, { origin = origin })
      end, page.items),
      next_cursor = page.next_cursor,
    }
  end)
end

local discussions, discussions_all = common.lists(discussions_fetch)

--- One page of discussions (threads, including single comments and system
--- notes). Resolves with `gg.Page<gg.Discussion>`.
---@param args gg.NoteableArgs
---@param opts? { per_page?: integer, cursor?: string } per_page default 20
---@return gg.Task
function M.discussions(args, opts)
  return discussions(args, opts)
end

--- All discussions up to `opts.limit`. Resolves with `{ items: gg.Discussion[], truncated: boolean }`.
---@param args gg.NoteableArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Discussion[]) }
---@return gg.Task
function M.discussions_all(args, opts)
  return discussions_all(args, opts)
end

local LIST_SPEC = spec({ filter = common.enum(true, "all", "comments", "activity") })

local function notes_fetch(args, o)
  local err = common.check(args, LIST_SPEC)
  if err then
    return task.failed(err)
  end
  local origin = common.origin(args.host)
  return task.run(function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local name = args.noteable == "issue" and "issue_notes" or "mr_notes"
    local conn = args.noteable == "issue" and "project.issue.notes" or "project.mergeRequest.notes"
    local page, gerr = graphql.page(args.host, name, {
      fullPath = path,
      iid = tostring(args.iid),
      filter = FILTER[args.filter or "all"],
    }, conn, {
      cursor = o.cursor,
      per_page = o.per_page,
      default_per_page = M.NOTES_PER_PAGE,
      what = what(args, path),
    }):await()
    if not page then
      return nil, gerr
    end
    return {
      items = vim.tbl_map(function(n)
        return note_model.note_from_graphql(n, { origin = origin })
      end, page.items),
      next_cursor = page.next_cursor,
    }
  end)
end

local notes, notes_all = common.lists(notes_fetch)

--- One page of notes in creation order, flat. `filter`: "all" (default),
--- "comments" (no system notes) or "activity" (system notes only).
--- Resolves with `gg.Page<gg.Note>`.
---@param args gg.NoteableArgs|{ filter?: "all"|"comments"|"activity" }
---@param opts? { per_page?: integer, cursor?: string } per_page default 100
---@return gg.Task
function M.list(args, opts)
  return notes(args, opts)
end

--- All notes up to `opts.limit`. Resolves with `{ items: gg.Note[], truncated: boolean }`.
---@param args gg.NoteableArgs|{ filter?: "all"|"comments"|"activity" }
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Note[]) }
---@return gg.Task
function M.list_all(args, opts)
  return notes_all(args, opts)
end

---@class gg.NewPosition
---@field new_path string
---@field old_path? string defaults to new_path
---@field new_line? integer
---@field old_line? integer
---@field position_type? "text"|"image"|"file" default "text"
---@field base_sha? string looked up from the latest diff version when missing
---@field start_sha? string
---@field head_sha? string
---@field line_range? table REST line_range for multi-line comments

local POSITION_KEYS = {
  new_path = "string",
  old_path = "string",
  new_line = "number",
  old_line = "number",
  position_type = "string",
  base_sha = "string",
  start_sha = "string",
  head_sha = "string",
  line_range = "table",
}

local function check_position(p)
  if type(p) ~= "table" then
    return common.invalid("position", "must be a table")
  end
  for k, v in pairs(p) do
    local want = POSITION_KEYS[k]
    if not want then
      return common.invalid("position." .. tostring(k), "is not a known position field")
    end
    if type(v) ~= want then
      return common.invalid("position." .. k, "must be a " .. want)
    end
  end
  if type(p.new_path) ~= "string" or p.new_path == "" then
    return common.invalid("position.new_path", "is required")
  end
  return nil
end

---@class gg.NoteAddArgs : gg.NoteableArgs
---@field body string
---@field position? gg.NewPosition merge requests only: a diff comment

--- Start a discussion (a comment, or a diff comment with `position`).
--- Resolves with the new `gg.Discussion`.
---@param args gg.NoteAddArgs
---@return gg.Task
function M.add(args)
  local err = common.check(args, spec({ body = "string", position = "table?" }))
  if err then
    return task.failed(err)
  end
  if args.position ~= nil then
    if args.noteable ~= "merge_request" then
      return task.failed(common.invalid("position", "only applies to merge requests"))
    end
    local perr = check_position(args.position)
    if perr then
      return task.failed(perr)
    end
  end
  return task.run(function()
    local body = { body = args.body }
    if args.position then
      local p = vim.deepcopy(args.position)
      if not (p.base_sha and p.start_sha and p.head_sha) then
        local version, verr = mr_changes.latest_version({ host = args.host, project = args.project, iid = args.iid }):await()
        if not version then
          return nil, verr
        end
        p.base_sha = p.base_sha or version.base_commit_sha
        p.start_sha = p.start_sha or version.start_commit_sha
        p.head_sha = p.head_sha or version.head_commit_sha
      end
      p.position_type = p.position_type or "text"
      p.old_path = p.old_path or p.new_path
      body.position = p
    end
    local res, rerr = rest.request(args.host, "POST", noteable_path(args, "/discussions"), { body = body }):await()
    if rerr then
      return nil, rerr
    end
    local d = note_model.discussion_from_rest(res.data, { origin = common.origin(args.host) })
    if not d then
      return nil, common.invalid("body", "was accepted, but GitLab returned no discussion")
    end
    return d
  end)
end

--- Reply in a discussion. Resolves with the new `gg.Note`.
---@param args gg.NoteableArgs|{ discussion_id: string, body: string }
---@return gg.Task
function M.reply(args)
  return common.run(args, spec({ discussion_id = "string", body = "string" }), function()
    local path = noteable_path(args, "/discussions/" .. rest.seg(args.discussion_id) .. "/notes")
    local res, err = rest.request(args.host, "POST", path, { body = { body = args.body } }):await()
    if err then
      return nil, err
    end
    return note_model.note_from_rest(res.data, { origin = common.origin(args.host), discussion_id = args.discussion_id })
  end)
end

local function note_path(args)
  if args.discussion_id then
    return noteable_path(args, ("/discussions/%s/notes/%d"):format(rest.seg(args.discussion_id), common.int(args.note_id)))
  end
  return noteable_path(args, ("/notes/%d"):format(common.int(args.note_id)))
end

--- Edit a note's body. Resolves with the updated `gg.Note`.
---@param args gg.NoteableArgs|{ note_id: integer, body: string, discussion_id?: string }
---@return gg.Task
function M.edit(args)
  return common.run(args, spec({ note_id = "id", body = "string", discussion_id = "string?" }), function()
    local res, err = rest.request(args.host, "PUT", note_path(args), { body = { body = args.body } }):await()
    if err then
      return nil, err
    end
    return note_model.note_from_rest(res.data, { origin = common.origin(args.host), discussion_id = args.discussion_id })
  end)
end

--- Delete a note. Resolves with `true`.
---@param args gg.NoteableArgs|{ note_id: integer, discussion_id?: string }
---@return gg.Task
function M.delete(args)
  return common.run(args, spec({ note_id = "id", discussion_id = "string?" }), function()
    local _, err = rest.request(args.host, "DELETE", note_path(args)):await()
    if err then
      return nil, err
    end
    return true
  end)
end

--- Resolve or unresolve a thread. Resolves with the updated `gg.Discussion`.
---@param args gg.NoteableArgs|{ discussion_id: string, resolved: boolean }
---@return gg.Task
function M.set_resolved(args)
  return common.run(args, spec({ discussion_id = "string", resolved = "boolean" }), function()
    local origin = common.origin(args.host)
    if args.noteable == "merge_request" then
      local path = noteable_path(args, "/discussions/" .. rest.seg(args.discussion_id))
      local res, err = rest.request(args.host, "PUT", path, { body = { resolved = args.resolved } }):await()
      if err then
        return nil, err
      end
      return note_model.discussion_from_rest(res.data, { origin = origin })
    end
    local data, err = graphql.query(args.host, "discussion_toggle_resolve", {
      id = gid.build("Discussion", args.discussion_id),
      resolve = args.resolved,
    }):await()
    if err then
      return nil, err
    end
    local perr = graphql.payload_error(data.discussionToggleResolve, "DiscussionToggleResolve")
    if perr then
      return nil, perr
    end
    local node, nerr = graphql.require(data, "discussionToggleResolve.discussion", "discussion " .. args.discussion_id)
    if not node then
      return nil, nerr
    end
    return note_model.discussion_from_graphql(node, { origin = origin })
  end)
end

return M
