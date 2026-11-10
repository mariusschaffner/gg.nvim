--- Repository branches.
---
--- Backend: REST (`/projects/:id/repository/branches`). GraphQL only exposes
--- branch names (`repository.branchNames`, offset paging, no commit data).
local branch_model = require("gg.models.branch")
local common = require("gg.resources.common")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

M.DEFAULT_PER_PAGE = 100

---@class gg.BranchListArgs
---@field host string
---@field project string|integer
---@field search? string names containing this; "^term" = starts with, "term$" = ends with
---@field regex? string an re2 regular expression (cannot be combined with search)

local SPEC = { host = "host", project = "project", search = "string?", regex = "string?" }

local function fetch_page(args, o)
  local err = common.check(args, SPEC)
  if err then
    return task.failed(err)
  end
  if args.search and args.regex then
    return task.failed(common.invalid("regex", "cannot be combined with args.search"))
  end
  return task.run(function()
    local page, rerr = rest.page(args.host, ("/projects/%s/repository/branches"):format(rest.project(args.project)), {
      query = { search = args.search, regex = args.regex },
      per_page = o.per_page,
      default_per_page = M.DEFAULT_PER_PAGE,
      cursor = o.cursor,
    }):await()
    if not page then
      return nil, rerr
    end
    return { items = vim.tbl_map(branch_model.from_rest, page.items), next_cursor = page.next_cursor }
  end)
end

local list, list_all = common.lists(fetch_page)

--- One page of branches (sorted by name). Resolves with `gg.Page<gg.Branch>`.
---@param args gg.BranchListArgs
---@param opts? { per_page?: integer, cursor?: string } per_page default 100
---@return gg.Task
function M.list(args, opts)
  return list(args, opts)
end

--- All branches up to `opts.limit`. Resolves with `{ items: gg.Branch[], truncated: boolean }`.
---@param args gg.BranchListArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Branch[]) }
---@return gg.Task
function M.list_all(args, opts)
  return list_all(args, opts)
end

local function related_args(args)
  local err = common.check(args, { host = "host", project = "project", iid = "id" })
  if err then
    return nil, err
  end
  return { host = args.host, project = args.project, search = ("^%d-"):format(common.int(args.iid)) }, nil
end

--- Branches named after an issue (`<iid>-...`, GitLab's convention), found
--- server-side with a prefix search, so nothing is missed beyond one page.
---@param args { host: string, project: string|integer, iid: integer }
---@param opts? { per_page?: integer, cursor?: string }
---@return gg.Task resolves with gg.Page<gg.Branch>
function M.related_to_issue(args, opts)
  local a, err = related_args(args)
  if not a then
    return task.failed(err)
  end
  return list(a, opts)
end

--- All branches named after an issue, up to `opts.limit`.
---@param args { host: string, project: string|integer, iid: integer }
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Branch[]) }
---@return gg.Task resolves with { items: gg.Branch[], truncated: boolean }
function M.related_to_issue_all(args, opts)
  local a, err = related_args(args)
  if not a then
    return task.failed(err)
  end
  return list_all(a, opts)
end

--- One branch by its exact name; a `not_found` error when the repository on
--- GitLab has no such branch.
---@param args { host: string, project: string|integer, name: string }
---@return gg.Task resolves with gg.Branch
function M.get(args)
  return common.run(args, { host = "host", project = "project", name = "string" }, function()
    local path = ("/projects/%s/repository/branches/%s"):format(rest.project(args.project), rest.seg(args.name))
    local res, err = rest.request(args.host, "GET", path):await()
    if err then
      return nil, err
    end
    return branch_model.from_rest(res.data)
  end)
end

--- Create a branch from a branch name or commit SHA.
---@param args { host: string, project: string|integer, branch: string, ref: string }
---@return gg.Task resolves with gg.Branch
function M.create(args)
  return common.run(args, { host = "host", project = "project", branch = "string", ref = "string" }, function()
    local res, err = rest.request(args.host, "POST", ("/projects/%s/repository/branches"):format(rest.project(args.project)), {
      query = { branch = args.branch, ref = args.ref },
    }):await()
    if err then
      return nil, err
    end
    return branch_model.from_rest(res.data)
  end)
end

return M
