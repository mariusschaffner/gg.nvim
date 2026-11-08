--- To-do items of the current user.
---
--- Backends: list via GraphQL `currentUser.todos`; mark_done via REST
--- `POST /todos/:id/mark_as_done` (writes stay on REST).
local common = require("gg.resources.common")
local errors = require("gg.core.errors")
local graphql = require("gg.graphql.client")
local rest = require("gg.rest.client")
local task = require("gg.core.task")
local todo_model = require("gg.models.todo")

local M = {}

M.DEFAULT_PER_PAGE = 50

local TYPE_ENUM = {
  issue = "ISSUE",
  merge_request = "MERGEREQUEST",
  commit = "COMMIT",
  work_item = "WORKITEM",
  epic = "EPIC",
  design = "DESIGN",
  alert = "ALERT",
}
local TYPE_NAMES = vim.tbl_keys(TYPE_ENUM)
table.sort(TYPE_NAMES)

---@class gg.TodoListArgs
---@field host string
---@field state? "pending"|"done"|"all" default "pending"
---@field type? "issue"|"merge_request"|"commit"|"work_item"|"epic"|"design"|"alert"
---@field action? string e.g. "assigned", "mentioned", "review_requested"
---@field sort? "created_desc"|"created_asc"|"updated_desc"|"updated_asc"

local LIST_SPEC = {
  host = "host",
  state = common.enum(true, "pending", "done", "all"),
  type = vim.tbl_extend("force", vim.deepcopy(TYPE_NAMES), { optional = true }),
  action = "string?",
  sort = common.enum(true, "created_desc", "created_asc", "updated_desc", "updated_asc"),
}

local function fetch_page(args, o)
  local err = common.check(args, LIST_SPEC)
  if err then
    return task.failed(err)
  end
  local origin = common.origin(args.host)
  return task.run(function()
    local state = args.state or "pending"
    local vars = {
      state = state ~= "all" and { state } or nil,
      type = args.type and { TYPE_ENUM[args.type] } or nil,
      action = args.action and { args.action } or nil,
      sort = args.sort and args.sort:upper() or nil,
    }
    local page, gerr = graphql.page(args.host, "todos_list", vars, "currentUser.todos", {
      cursor = o.cursor,
      per_page = o.per_page,
      default_per_page = M.DEFAULT_PER_PAGE,
      what = "the current user",
    }):await()
    if not page then
      if gerr.kind == "not_found" then
        return nil, errors.new("auth", ("no signed-in user on %s (is a token configured?)"):format(args.host), {
          details = { host = args.host },
        })
      end
      return nil, gerr
    end
    return {
      items = vim.tbl_map(function(n)
        return todo_model.from_graphql(n, { origin = origin })
      end, page.items),
      next_cursor = page.next_cursor,
    }
  end)
end

local list, list_all = common.lists(fetch_page)

--- One page of to-do items (pending by default). Resolves with `gg.Page<gg.Todo>`.
---@param args gg.TodoListArgs
---@param opts? { per_page?: integer, cursor?: string } per_page default 50
---@return gg.Task
function M.list(args, opts)
  return list(args, opts)
end

--- All to-do items up to `opts.limit`. Resolves with `{ items: gg.Todo[], truncated: boolean }`.
---@param args gg.TodoListArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Todo[]) }
---@return gg.Task
function M.list_all(args, opts)
  return list_all(args, opts)
end

--- Mark a to-do item as done.
---@param args { host: string, id: integer }
---@return gg.Task resolves with the updated gg.Todo
function M.mark_done(args)
  return common.run(args, { host = "host", id = "id" }, function()
    local res, err = rest.request(args.host, "POST", ("/todos/%s/mark_as_done"):format(rest.seg(common.int(args.id)))):await()
    if err then
      return nil, err
    end
    return todo_model.from_rest(res.data, { origin = common.origin(args.host) })
  end)
end

return M
