--- Projects: search and a minimal get.
---
--- Backend: GraphQL `projects(search:)` sorted by `latest_activity_desc`
--- (most recently active first; unknown sort values are silently ignored by
--- GitLab), and `project(fullPath:)`.
local common = require("gg.resources.common")
local graphql = require("gg.graphql.client")
local project_model = require("gg.models.project")
local task = require("gg.core.task")

local M = {}

M.DEFAULT_PER_PAGE = 20

---@class gg.ProjectSearchArgs
---@field host string
---@field query string name, path or description
---@field membership? boolean only projects the user is a member of

local SEARCH_SPEC = { host = "host", query = "string", membership = "boolean?" }

local function fetch_page(args, o)
  local err = common.check(args, SEARCH_SPEC)
  if err then
    return task.failed(err)
  end
  return task.run(function()
    local page, gerr = graphql.page(args.host, "projects_search", {
      search = args.query,
      membership = args.membership,
      sort = "latest_activity_desc",
    }, "projects", {
      cursor = o.cursor,
      per_page = o.per_page,
      default_per_page = M.DEFAULT_PER_PAGE,
    }):await()
    if not page then
      return nil, gerr
    end
    return { items = vim.tbl_map(project_model.from_graphql, page.items), next_cursor = page.next_cursor }
  end)
end

local list, list_all = common.lists(fetch_page)

--- One page of projects matching a search, most recently active first.
--- Resolves with `gg.Page<gg.Project>`.
---@param args gg.ProjectSearchArgs
---@param opts? { per_page?: integer, cursor?: string } per_page default 20
---@return gg.Task
function M.search(args, opts)
  return list(args, opts)
end

--- All matching projects up to `opts.limit`. Resolves with `{ items: gg.Project[], truncated: boolean }`.
---@param args gg.ProjectSearchArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Project[]) }
---@return gg.Task
function M.search_all(args, opts)
  return list_all(args, opts)
end

--- One project, by full path or numeric ID.
---@param args { host: string, project: string|integer }
---@return gg.Task resolves with gg.Project
function M.get(args)
  return common.run(args, { host = "host", project = "project" }, function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local data, err = graphql.query(args.host, "project_get", { fullPath = path }):await()
    if err then
      return nil, err
    end
    local node, nerr = graphql.require(data, "project", "project " .. path)
    if not node then
      return nil, nerr
    end
    return project_model.from_graphql(node)
  end)
end

return M
