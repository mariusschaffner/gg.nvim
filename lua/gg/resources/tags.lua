--- Repository tags (read-only).
---
--- Backend: REST (`/projects/:id/repository/tags`); GraphQL only exposes tag
--- names (`repository.tagNames`), without the commit.
local common = require("gg.resources.common")
local rest = require("gg.rest.client")
local tag_model = require("gg.models.tag")
local task = require("gg.core.task")

local M = {}

M.DEFAULT_PER_PAGE = 100

---@class gg.TagListArgs
---@field host string
---@field project string|integer
---@field search? string names containing this; "^term" = starts with, "term$" = ends with
---@field order_by? "name"|"updated"|"version" default "updated"
---@field sort? "asc"|"desc" default "desc"

local SPEC = {
  host = "host",
  project = "project",
  search = "string?",
  order_by = common.enum(true, "name", "updated", "version"),
  sort = common.enum(true, "asc", "desc"),
}

local function fetch_page(args, o)
  local err = common.check(args, SPEC)
  if err then
    return task.failed(err)
  end
  return task.run(function()
    local page, rerr = rest.page(args.host, ("/projects/%s/repository/tags"):format(rest.project(args.project)), {
      query = { search = args.search, order_by = args.order_by, sort = args.sort },
      per_page = o.per_page,
      default_per_page = M.DEFAULT_PER_PAGE,
      cursor = o.cursor,
    }):await()
    if not page then
      return nil, rerr
    end
    return { items = vim.tbl_map(tag_model.from_rest, page.items), next_cursor = page.next_cursor }
  end)
end

local list, list_all = common.lists(fetch_page)

--- One page of tags (most recently updated first). Resolves with `gg.Page<gg.Tag>`.
---@param args gg.TagListArgs
---@param opts? { per_page?: integer, cursor?: string } per_page default 100
---@return gg.Task
function M.list(args, opts)
  return list(args, opts)
end

--- All tags up to `opts.limit`. Resolves with `{ items: gg.Tag[], truncated: boolean }`.
---@param args gg.TagListArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Tag[]) }
---@return gg.Task
function M.list_all(args, opts)
  return list_all(args, opts)
end

return M
