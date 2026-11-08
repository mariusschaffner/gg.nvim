--- Issues.
---
--- Backends (GraphQL-first for reads):
---   * list (project or group), get, by_iids: GraphQL `project.issues` /
---     `group.issues` / `project.issue`.
---   * list across all projects (no project or group): REST `GET /issues`.
---     The GraphQL equivalent (`Query.issues`) is marked Experiment.
---   * create, update: REST (`POST /projects/:id/issues`,
---     `PUT /projects/:id/issues/:iid`).
local common = require("gg.resources.common")
local graphql = require("gg.graphql.client")
local issue_model = require("gg.models.issue")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

M.DEFAULT_PER_PAGE = 50

-- order_by -> GraphQL IssueSort prefix
local SORT = {
  created_at = "CREATED",
  updated_at = "UPDATED",
  due_date = "DUE_DATE",
  title = "TITLE",
  priority = "PRIORITY",
  label_priority = "LABEL_PRIORITY",
  milestone_due = "MILESTONE_DUE",
  popularity = "POPULARITY",
  weight = "WEIGHT",
  closed_at = "CLOSED_AT",
  relative_position = "RELATIVE_POSITION",
}
local REST_ORDER = {
  created_at = true,
  updated_at = true,
  due_date = true,
  title = true,
  priority = true,
  label_priority = true,
  milestone_due = true,
  popularity = true,
  weight = true,
  relative_position = true,
}

local ORDER_BY = vim.tbl_keys(SORT)
table.sort(ORDER_BY)

local TYPES = { "issue", "incident", "test_case", "task", "requirement", "ticket", "objective", "key_result", "epic" }

---@class gg.IssueListArgs
---@field host string
---@field project? string|integer project path or ID (GraphQL)
---@field group? string group full path (GraphQL)
---@field scope? "created_by_me"|"assigned_to_me"|"all" only without project/group (REST)
---@field state? "opened"|"closed"|"all"
---@field labels? string[]|string issues must have all of these labels
---@field milestone? string milestone title, or "None" / "Any"
---@field assignee_username? string a username, or "None" / "Any"
---@field author_username? string
---@field search? string
---@field iids? integer[]
---@field order_by? string created_at, updated_at, due_date, title, priority, ...
---@field sort? "asc"|"desc"
---@field confidential? boolean
---@field types? string[] issue types (issue, incident, test_case, task, ...)
---@field include_subgroups? boolean groups only; default true (like REST)

local LIST_SPEC = {
  host = "host",
  project = "project?",
  group = "group?",
  scope = common.enum(true, "created_by_me", "assigned_to_me", "all"),
  state = common.enum(true, "opened", "closed", "all"),
  labels = "strings?",
  milestone = "string?",
  assignee_username = "string?",
  author_username = "string?",
  search = "string?",
  iids = "ids?",
  order_by = vim.tbl_extend("force", vim.deepcopy(ORDER_BY), { optional = true }),
  sort = common.enum(true, "asc", "desc"),
  confidential = "boolean?",
  types = "strings?",
  include_subgroups = "boolean?",
}

local function check_list(args)
  local err = common.check(args, LIST_SPEC)
  if err then
    return err
  end
  if args.project and args.group then
    return common.invalid("group", "cannot be combined with args.project")
  end
  if args.scope and (args.project or args.group) then
    return common.invalid("scope", "only applies to lists across all projects (without project or group)")
  end
  if args.include_subgroups ~= nil and not args.group then
    return common.invalid("include_subgroups", "only applies with args.group")
  end
  for _, t in ipairs(common.list(args.types) or {}) do
    if not vim.tbl_contains(TYPES, t) then
      return common.invalid("types", "must contain only: " .. table.concat(TYPES, ", "))
    end
  end
  if not args.project and not args.group then
    if args.order_by and not REST_ORDER[args.order_by] then
      return common.invalid("order_by", "is not supported for lists across all projects")
    end
    if args.types and #common.list(args.types) > 1 then
      return common.invalid("types", "accepts one type for lists across all projects")
    end
  end
  return nil
end

local function graphql_vars(args)
  local v = {}
  v.state = args.state
  v.labelName = common.list(args.labels)
  if args.milestone == "None" or args.milestone == "Any" then
    v.milestoneWildcardId = args.milestone:upper()
  elseif args.milestone then
    v.milestoneTitle = { args.milestone }
  end
  if args.assignee_username == "None" or args.assignee_username == "Any" then
    v.assigneeWildcardId = args.assignee_username:upper()
  elseif args.assignee_username then
    v.assigneeUsernames = { args.assignee_username }
  end
  v.authorUsername = args.author_username
  v.search = args.search
  if args.iids then
    v.iids = vim.tbl_map(tostring, args.iids)
  end
  if args.order_by or args.sort then
    v.sort = SORT[args.order_by or "created_at"] .. "_" .. (args.sort or "desc"):upper()
  end
  v.confidential = args.confidential
  if args.types then
    v.types = vim.tbl_map(string.upper, common.list(args.types))
  end
  return v
end

local function rest_query(args)
  local q = {
    scope = args.scope,
    state = args.state,
    labels = common.csv(args.labels),
    milestone = args.milestone,
    assignee_username = args.assignee_username,
    author_username = args.author_username,
    search = args.search,
    iids = args.iids,
    order_by = args.order_by,
    sort = args.sort,
    confidential = args.confidential,
    with_labels_details = true,
  }
  if args.types then
    q.issue_type = common.list(args.types)[1]
  end
  return q
end

local function fetch_page(args, o)
  local err = check_list(args)
  if err then
    return task.failed(err)
  end
  local origin = common.origin(args.host)
  return task.run(function()
    if args.project or args.group then
      local name, path, conn, what, vars
      vars = graphql_vars(args)
      if args.project then
        local perr
        path, perr = graphql.project_path(args.host, args.project):await()
        if not path then
          return nil, perr
        end
        name, conn, what = "issues_list_project", "project.issues", "project " .. path
      else
        path = args.group
        name, conn, what = "issues_list_group", "group.issues", "group " .. path
        vars.includeSubgroups = args.include_subgroups ~= false
      end
      vars.fullPath = path
      local page, gerr = graphql.page(args.host, name, vars, conn, {
        cursor = o.cursor,
        per_page = o.per_page,
        default_per_page = M.DEFAULT_PER_PAGE,
        what = what,
      }):await()
      if not page then
        return nil, gerr
      end
      local ctx = { origin = origin, project = args.project and path or nil }
      return {
        items = vim.tbl_map(function(n)
          return issue_model.from_graphql(n, ctx)
        end, page.items),
        next_cursor = page.next_cursor,
      }
    end
    local page, rerr = rest.page(args.host, "/issues", {
      query = rest_query(args),
      per_page = o.per_page,
      default_per_page = M.DEFAULT_PER_PAGE,
      cursor = o.cursor,
    }):await()
    if not page then
      return nil, rerr
    end
    local ctx = { origin = origin }
    return {
      items = vim.tbl_map(function(raw)
        return issue_model.from_rest(raw, ctx)
      end, page.items),
      next_cursor = page.next_cursor,
    }
  end)
end

local list, list_all = common.lists(fetch_page)

--- One page of issues. Resolves with `gg.Page<gg.Issue>`.
--- With `project` or `group`: GraphQL. Without: REST `GET /issues` (all
--- projects visible to the token; `scope` defaults to GitLab's created_by_me).
---@param args gg.IssueListArgs
---@param opts? { per_page?: integer, cursor?: string } per_page default 50
---@return gg.Task
function M.list(args, opts)
  return list(args, opts)
end

--- All issues up to `opts.limit`. Resolves with `{ items: gg.Issue[], truncated: boolean }`.
---@param args gg.IssueListArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Issue[]) }
---@return gg.Task
function M.list_all(args, opts)
  return list_all(args, opts)
end

--- One issue with its description and subscription state.
---@param args { host: string, project: string|integer, iid: integer }
---@return gg.Task resolves with gg.Issue
function M.get(args)
  return common.run(args, { host = "host", project = "project", iid = "id" }, function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local data, err = graphql.query(args.host, "issue_get", { fullPath = path, iid = tostring(args.iid) }):await()
    if err then
      return nil, err
    end
    local node, nerr = graphql.require(data, "project.issue", ("issue %s#%s"):format(path, tostring(args.iid)))
    if not node then
      return nil, nerr
    end
    return issue_model.from_graphql(node, { origin = common.origin(args.host), project = path })
  end)
end

--- Issues by IID (any order). Missing IIDs are simply absent.
---@param args { host: string, project: string|integer, iids: integer[] }
---@return gg.Task resolves with gg.Issue[]
function M.by_iids(args)
  return common.run(args, { host = "host", project = "project", iids = "ids" }, function()
    if #args.iids == 0 then
      return {}
    end
    local res, err = list_all({ host = args.host, project = args.project, iids = args.iids, state = "all" }, {
      limit = #args.iids,
      per_page = math.min(#args.iids, 100),
    }):await()
    if err then
      return nil, err
    end
    return res.items
  end)
end

---@class gg.IssueCreateArgs
---@field host string
---@field project string|integer
---@field title string
---@field description? string
---@field labels? string[]|string
---@field assignee_ids? integer[]
---@field milestone_id? integer
---@field confidential? boolean
---@field due_date? string YYYY-MM-DD
---@field issue_type? "issue"|"incident"|"test_case"|"task"
---@field weight? integer

--- Create an issue (REST).
---@param args gg.IssueCreateArgs
---@return gg.Task resolves with gg.Issue
function M.create(args)
  local spec = {
    host = "host",
    project = "project",
    title = "string",
    description = "text?",
    labels = "strings?",
    assignee_ids = "ids?",
    milestone_id = "id?",
    confidential = "boolean?",
    due_date = "date?",
    issue_type = common.enum(true, "issue", "incident", "test_case", "task"),
    weight = "count?",
  }
  return common.run(args, spec, function()
    local seg = rest.project(args.project)
    local body = {
      title = args.title,
      description = args.description,
      labels = common.csv(args.labels),
      assignee_ids = args.assignee_ids,
      milestone_id = common.int(args.milestone_id),
      confidential = args.confidential,
      due_date = args.due_date,
      issue_type = args.issue_type,
      weight = args.weight,
    }
    local res, err = rest.request(args.host, "POST", "/projects/" .. seg .. "/issues", { body = body }):await()
    if err then
      return nil, err
    end
    return issue_model.from_rest(res.data, { origin = common.origin(args.host) })
  end)
end

---@class gg.IssueUpdateArgs
---@field host string
---@field project string|integer
---@field iid integer
---@field title? string
---@field description? string
---@field state_event? "close"|"reopen"
---@field labels? string[]|string replaces all labels; {} or "" removes them
---@field add_labels? string[]|string
---@field remove_labels? string[]|string
---@field assignee_ids? integer[] replaces the assignees; {} unassigns everyone
---@field milestone_id? integer|false false removes the milestone
---@field due_date? string YYYY-MM-DD
---@field confidential? boolean
---@field issue_type? "issue"|"incident"|"test_case"
---@field weight? integer
---@field discussion_locked? boolean

local UPDATE_FIELDS = {
  "title",
  "description",
  "state_event",
  "labels",
  "add_labels",
  "remove_labels",
  "assignee_ids",
  "milestone_id",
  "due_date",
  "confidential",
  "issue_type",
  "weight",
  "discussion_locked",
}

--- Update an issue (REST). At least one field besides host/project/iid.
---@param args gg.IssueUpdateArgs
---@return gg.Task resolves with the updated gg.Issue
function M.update(args)
  local spec = {
    host = "host",
    project = "project",
    iid = "id",
    title = "string?",
    description = "text?",
    state_event = common.enum(true, "close", "reopen"),
    labels = "strings?",
    add_labels = "strings?",
    remove_labels = "strings?",
    assignee_ids = "ids?",
    milestone_id = "id_or_false?",
    due_date = "date?",
    confidential = "boolean?",
    issue_type = common.enum(true, "issue", "incident", "test_case"),
    weight = "count?",
    discussion_locked = "boolean?",
  }
  local err = common.check(args, spec)
  if err then
    return task.failed(err)
  end
  local body = {}
  for _, k in ipairs(UPDATE_FIELDS) do
    body[k] = args[k]
  end
  if next(body) == nil then
    return task.failed(common.invalid("title", "(or another field) is required: nothing to update"))
  end
  if args.labels ~= nil then
    body.labels = common.csv(args.labels) -- "" removes all labels
  end
  body.add_labels = common.csv(args.add_labels)
  body.remove_labels = common.csv(args.remove_labels)
  if args.assignee_ids ~= nil and #args.assignee_ids == 0 then
    body.assignee_ids = { 0 } -- documented: 0 unassigns everyone
  end
  if args.milestone_id == false then
    body.milestone_id = 0 -- documented: 0 removes the milestone
  elseif args.milestone_id ~= nil then
    body.milestone_id = common.int(args.milestone_id)
  end
  return task.run(function()
    local seg = rest.project(args.project)
    local res, rerr = rest.request(args.host, "PUT", ("/projects/%s/issues/%d"):format(seg, common.int(args.iid)), { body = body }):await()
    if rerr then
      return nil, rerr
    end
    return issue_model.from_rest(res.data, { origin = common.origin(args.host) })
  end)
end

return M
