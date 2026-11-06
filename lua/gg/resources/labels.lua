--- Labels of a project (including its ancestor groups' labels by default).
---
--- Backend: GraphQL `project.labels` (it takes the same search and ancestor
--- options as REST `GET /projects/:id/labels`).
local common = require("gg.resources.common")
local graphql = require("gg.graphql.client")
local label_model = require("gg.models.label")
local task = require("gg.core.task")

local M = {}

M.DEFAULT_PER_PAGE = 100

---@class gg.LabelListArgs
---@field host string
---@field project string|integer
---@field search? string match label titles
---@field include_ancestor_groups? boolean default true (group labels count too)

local SPEC = { host = "host", project = "project", search = "string?", include_ancestor_groups = "boolean?" }

local function fetch_page(args, o)
  local err = common.check(args, SPEC)
  if err then
    return task.failed(err)
  end
  return task.run(function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local page, gerr = graphql.page(args.host, "labels_list", {
      fullPath = path,
      searchTerm = args.search,
      searchIn = { "TITLE" },
      includeAncestorGroups = args.include_ancestor_groups ~= false,
    }, "project.labels", {
      cursor = o.cursor,
      per_page = o.per_page,
      default_per_page = M.DEFAULT_PER_PAGE,
      what = "project " .. path,
    }):await()
    if not page then
      return nil, gerr
    end
    return { items = vim.tbl_map(label_model.from_graphql, page.items), next_cursor = page.next_cursor }
  end)
end

local list, list_all = common.lists(fetch_page)

--- One page of labels. Resolves with `gg.Page<gg.Label>`.
---@param args gg.LabelListArgs
---@param opts? { per_page?: integer, cursor?: string } per_page default 100
---@return gg.Task
function M.list(args, opts)
  return list(args, opts)
end

--- All labels up to `opts.limit`. Resolves with `{ items: gg.Label[], truncated: boolean }`.
---@param args gg.LabelListArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Label[]) }
---@return gg.Task
function M.list_all(args, opts)
  return list_all(args, opts)
end

return M
