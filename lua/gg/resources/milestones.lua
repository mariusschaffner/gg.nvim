--- Milestones.
---
--- Backends:
---   * list: GraphQL `project.milestones` (ancestor-group milestones included
---     by default, like atlas's milestone pickers).
---   * get: GraphQL `milestone(id:)` (works for project and group milestones).
---   * issues / merge_requests: the GraphQL issue and MR lists filtered by the
---     milestone title (the Milestone type has no issue connection).
---   * create, update: REST `/projects/:id/milestones`.
local common = require("gg.resources.common")
local gid = require("gg.models.gid")
local graphql = require("gg.graphql.client")
local issues = require("gg.resources.issues")
local merge_requests = require("gg.resources.merge_requests")
local milestone_model = require("gg.models.milestone")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

M.DEFAULT_PER_PAGE = 100

local SORT = { due_date = "DUE_DATE", created_at = "CREATED", updated_at = "UPDATED" }

---@class gg.MilestoneListArgs
---@field host string
---@field project string|integer
---@field state? "active"|"closed"|"all" default "active"
---@field search? string match titles
---@field include_ancestors? boolean default true (group milestones count too)
---@field order_by? "due_date"|"created_at"|"updated_at"
---@field sort? "asc"|"desc"

local LIST_SPEC = {
  host = "host",
  project = "project",
  state = common.enum(true, "active", "closed", "all"),
  search = "string?",
  include_ancestors = "boolean?",
  order_by = common.enum(true, "due_date", "created_at", "updated_at"),
  sort = common.enum(true, "asc", "desc"),
}

local function fetch_page(args, o)
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
    local state = args.state or "active"
    local vars = {
      fullPath = path,
      state = state ~= "all" and state or nil,
      searchTitle = args.search,
      includeAncestors = args.include_ancestors ~= false,
    }
    if args.order_by or args.sort then
      vars.sort = SORT[args.order_by or "due_date"] .. "_" .. (args.sort or "asc"):upper()
    end
    local page, gerr = graphql.page(args.host, "milestones_list", vars, "project.milestones", {
      cursor = o.cursor,
      per_page = o.per_page,
      default_per_page = M.DEFAULT_PER_PAGE,
      what = "project " .. path,
    }):await()
    if not page then
      return nil, gerr
    end
    return {
      items = vim.tbl_map(function(n)
        return milestone_model.from_graphql(n, { origin = origin })
      end, page.items),
      next_cursor = page.next_cursor,
    }
  end)
end

local list, list_all = common.lists(fetch_page)

--- One page of milestones. Resolves with `gg.Page<gg.Milestone>`.
---@param args gg.MilestoneListArgs
---@param opts? { per_page?: integer, cursor?: string } per_page default 100
---@return gg.Task
function M.list(args, opts)
  return list(args, opts)
end

--- All milestones up to `opts.limit`. Resolves with `{ items: gg.Milestone[], truncated: boolean }`.
---@param args gg.MilestoneListArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Milestone[]) }
---@return gg.Task
function M.list_all(args, opts)
  return list_all(args, opts)
end

--- One milestone by its (global, numeric) ID; project or group milestone.
---@param args { host: string, id: integer }
---@return gg.Task resolves with gg.Milestone
function M.get(args)
  return common.run(args, { host = "host", id = "id" }, function()
    local data, err = graphql.query(args.host, "milestone_get", { id = gid.build("Milestone", common.int(args.id)) }):await()
    if err then
      return nil, err
    end
    local node, nerr = graphql.require(data, "milestone", "milestone " .. tostring(args.id))
    if not node then
      return nil, nerr
    end
    return milestone_model.from_graphql(node, { origin = common.origin(args.host) })
  end)
end

---@class gg.MilestoneItemsArgs
---@field host string
---@field project string|integer
---@field title string the milestone title
---@field state? string issue / MR state filter (default: all states)

local ITEMS_SPEC = { host = "host", project = "project", title = "string", state = "string?" }

local function items_args(args)
  local err = common.check(args, ITEMS_SPEC)
  if err then
    return nil, err
  end
  return { host = args.host, project = args.project, milestone = args.title, state = args.state or "all" }, nil
end

--- One page of the milestone's issues in a project. Resolves with `gg.Page<gg.Issue>`.
---@param args gg.MilestoneItemsArgs
---@param opts? { per_page?: integer, cursor?: string }
---@return gg.Task
function M.issues(args, opts)
  local a, err = items_args(args)
  if not a then
    return task.failed(err)
  end
  return issues.list(a, opts)
end

--- All of the milestone's issues up to `opts.limit`.
---@param args gg.MilestoneItemsArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Issue[]) }
---@return gg.Task resolves with { items: gg.Issue[], truncated: boolean }
function M.issues_all(args, opts)
  local a, err = items_args(args)
  if not a then
    return task.failed(err)
  end
  return issues.list_all(a, opts)
end

--- One page of the milestone's merge requests in a project. Resolves with `gg.Page<gg.MergeRequest>`.
---@param args gg.MilestoneItemsArgs
---@param opts? { per_page?: integer, cursor?: string }
---@return gg.Task
function M.merge_requests(args, opts)
  local a, err = items_args(args)
  if not a then
    return task.failed(err)
  end
  return merge_requests.list(a, opts)
end

--- All of the milestone's merge requests up to `opts.limit`.
---@param args gg.MilestoneItemsArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.MergeRequest[]) }
---@return gg.Task resolves with { items: gg.MergeRequest[], truncated: boolean }
function M.merge_requests_all(args, opts)
  local a, err = items_args(args)
  if not a then
    return task.failed(err)
  end
  return merge_requests.list_all(a, opts)
end

--- Create a project milestone (REST).
---@param args { host: string, project: string|integer, title: string, description?: string, start_date?: string, due_date?: string }
---@return gg.Task resolves with gg.Milestone
function M.create(args)
  local spec = { host = "host", project = "project", title = "string", description = "text?", start_date = "date?", due_date = "date?" }
  return common.run(args, spec, function()
    local res, err = rest.request(args.host, "POST", ("/projects/%s/milestones"):format(rest.project(args.project)), {
      body = { title = args.title, description = args.description, start_date = args.start_date, due_date = args.due_date },
    }):await()
    if err then
      return nil, err
    end
    local project = type(args.project) == "string" and not args.project:match("^%d+$") and args.project or nil
    return milestone_model.from_rest(res.data, { project = project })
  end)
end

---@class gg.MilestoneUpdateArgs
---@field host string
---@field project string|integer
---@field id integer the milestone's global ID
---@field title? string
---@field description? string
---@field start_date? string YYYY-MM-DD
---@field due_date? string YYYY-MM-DD
---@field state_event? "close"|"activate"

--- Update a project milestone (REST). At least one field.
---@param args gg.MilestoneUpdateArgs
---@return gg.Task resolves with the updated gg.Milestone
function M.update(args)
  local spec = {
    host = "host",
    project = "project",
    id = "id",
    title = "string?",
    description = "text?",
    start_date = "date?",
    due_date = "date?",
    state_event = common.enum(true, "close", "activate"),
  }
  local err = common.check(args, spec)
  if err then
    return task.failed(err)
  end
  local body = {
    title = args.title,
    description = args.description,
    start_date = args.start_date,
    due_date = args.due_date,
    state_event = args.state_event,
  }
  if next(body) == nil then
    return task.failed(common.invalid("title", "(or another field) is required: nothing to update"))
  end
  return task.run(function()
    local path = ("/projects/%s/milestones/%d"):format(rest.project(args.project), common.int(args.id))
    local res, rerr = rest.request(args.host, "PUT", path, { body = body }):await()
    if rerr then
      return nil, rerr
    end
    local project = type(args.project) == "string" and not args.project:match("^%d+$") and args.project or nil
    return milestone_model.from_rest(res.data, { project = project })
  end)
end

return M
