--- Merge requests.
---
--- Backends (GraphQL-first for reads):
---   * list (project, group, or the current user's authored / assigned /
---     review-requested), get, by_iids: GraphQL.
---   * list with scope = "all" (every MR visible to the token): REST
---     `GET /merge_requests` (GraphQL has no equivalent).
---   * summaries (head pipeline stages + diff stats, by IID): GraphQL.
---   * related_to_issue: REST `/issues/:iid/related_merge_requests`.
---   * create, update, merge: REST. Draft status is not a REST parameter, so
---     it is set with the GraphQL `mergeRequestSetDraft` mutation.
local common = require("gg.resources.common")
local errors = require("gg.core.errors")
local graphql = require("gg.graphql.client")
local mr_model = require("gg.models.merge_request")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

M.DEFAULT_PER_PAGE = 50
M.RELATED_PER_PAGE = 20

local SORT = {
  created_at = "CREATED",
  updated_at = "UPDATED",
  merged_at = "MERGED_AT",
  closed_at = "CLOSED_AT",
  title = "TITLE",
  popularity = "POPULARITY",
  priority = "PRIORITY",
  label_priority = "LABEL_PRIORITY",
  milestone_due = "MILESTONE_DUE",
}
local REST_ORDER = { created_at = true, updated_at = true, title = true }
local ORDER_BY = vim.tbl_keys(SORT)
table.sort(ORDER_BY)

-- scope -> connection alias in merge_requests_list_mine.graphql
local MINE = { created_by_me = "authored", assigned_to_me = "assigned", reviews_for_me = "reviewRequested" }

---@class gg.MergeRequestListArgs
---@field host string
---@field project? string|integer project path or ID
---@field group? string group full path
---@field scope? "created_by_me"|"assigned_to_me"|"reviews_for_me"|"all" without project/group; default "created_by_me"
---@field state? "opened"|"closed"|"merged"|"locked"|"all"
---@field labels? string[]|string
---@field milestone? string a title, or "None" / "Any"
---@field author_username? string
---@field assignee_username? string a username, or "None" / "Any"
---@field reviewer_username? string a username, or "None" / "Any"
---@field search? string
---@field iids? integer[]
---@field source_branch? string
---@field target_branch? string
---@field draft? boolean
---@field order_by? string created_at, updated_at, merged_at, closed_at, title, ...
---@field sort? "asc"|"desc"
---@field include_subgroups? boolean groups only; default true

local LIST_SPEC = {
  host = "host",
  project = "project?",
  group = "group?",
  scope = common.enum(true, "created_by_me", "assigned_to_me", "reviews_for_me", "all"),
  state = common.enum(true, "opened", "closed", "merged", "locked", "all"),
  labels = "strings?",
  milestone = "string?",
  author_username = "string?",
  assignee_username = "string?",
  reviewer_username = "string?",
  search = "string?",
  iids = "ids?",
  source_branch = "string?",
  target_branch = "string?",
  draft = "boolean?",
  order_by = vim.tbl_extend("force", vim.deepcopy(ORDER_BY), { optional = true }),
  sort = common.enum(true, "asc", "desc"),
  include_subgroups = "boolean?",
}

-- filters the currentUser connections do not take
local NOT_FOR_MINE = { "author_username", "assignee_username", "reviewer_username", "iids" }

local function check_list(args)
  local err = common.check(args, LIST_SPEC)
  if err then
    return err
  end
  if args.project and args.group then
    return common.invalid("group", "cannot be combined with args.project")
  end
  if args.scope and (args.project or args.group) then
    return common.invalid("scope", "only applies without args.project and args.group")
  end
  if args.include_subgroups ~= nil and not args.group then
    return common.invalid("include_subgroups", "only applies with args.group")
  end
  if not args.project and not args.group then
    local scope = args.scope or "created_by_me"
    if scope == "all" then
      if args.order_by and not REST_ORDER[args.order_by] then
        return common.invalid("order_by", "with scope 'all' must be created_at, updated_at or title")
      end
      if args.milestone == "Any" then
        return common.invalid("milestone", "'Any' is not supported with scope 'all'")
      end
    else
      for _, k in ipairs(NOT_FOR_MINE) do
        if args[k] ~= nil then
          return common.invalid(k, ("is not supported with scope %q (use scope 'all' or a project)"):format(scope))
        end
      end
      if args.milestone == "None" or args.milestone == "Any" then
        return common.invalid("milestone", ("wildcards are not supported with scope %q"):format(scope))
      end
    end
  end
  return nil
end

local function wildcard(v)
  return v == "None" or v == "Any"
end

local function graphql_vars(args)
  local v = {
    state = args.state,
    labelName = common.list(args.labels),
    search = args.search,
    draft = args.draft,
    authorUsername = args.author_username,
  }
  if wildcard(args.milestone) then
    v.milestoneWildcardId = args.milestone:upper()
  else
    v.milestoneTitle = args.milestone
  end
  if wildcard(args.assignee_username) then
    v.assigneeWildcardId = args.assignee_username:upper()
  elseif args.assignee_username then
    v.assigneeUsernames = { args.assignee_username }
  end
  if wildcard(args.reviewer_username) then
    v.reviewerWildcardId = args.reviewer_username:upper()
  else
    v.reviewerUsername = args.reviewer_username
  end
  if args.iids then
    v.iids = vim.tbl_map(tostring, args.iids)
  end
  if args.source_branch then
    v.sourceBranches = { args.source_branch }
  end
  if args.target_branch then
    v.targetBranches = { args.target_branch }
  end
  if args.order_by or args.sort then
    v.sort = SORT[args.order_by or "created_at"] .. "_" .. (args.sort or "desc"):upper()
  end
  return v
end

local function rest_query(args)
  return {
    scope = "all",
    state = args.state,
    labels = common.csv(args.labels),
    milestone = args.milestone,
    author_username = args.author_username,
    assignee_username = args.assignee_username,
    reviewer_username = args.reviewer_username,
    search = args.search,
    iids = args.iids,
    source_branch = args.source_branch,
    target_branch = args.target_branch,
    draft = args.draft,
    order_by = args.order_by,
    sort = args.sort,
    with_labels_details = true,
  }
end

local function map_nodes(nodes, ctx)
  return vim.tbl_map(function(n)
    return mr_model.from_graphql(n, ctx)
  end, nodes)
end

local function fetch_page(args, o)
  local err = check_list(args)
  if err then
    return task.failed(err)
  end
  local origin = common.origin(args.host)
  local page_opts = { cursor = o.cursor, per_page = o.per_page, default_per_page = M.DEFAULT_PER_PAGE }
  return task.run(function()
    if args.project or args.group then
      local vars, name, conn, path = graphql_vars(args), nil, nil, nil
      if args.project then
        local perr
        path, perr = graphql.project_path(args.host, args.project):await()
        if not path then
          return nil, perr
        end
        name, conn, page_opts.what = "merge_requests_list_project", "project.mergeRequests", "project " .. path
      else
        path = args.group
        name, conn, page_opts.what = "merge_requests_list_group", "group.mergeRequests", "group " .. path
        vars.includeSubgroups = args.include_subgroups ~= false
      end
      vars.fullPath = path
      local page, gerr = graphql.page(args.host, name, vars, conn, page_opts):await()
      if not page then
        return nil, gerr
      end
      return { items = map_nodes(page.items, { origin = origin, project = args.project and path or nil }), next_cursor = page.next_cursor }
    end

    local scope = args.scope or "created_by_me"
    if scope == "all" then
      local page, rerr = rest.page(args.host, "/merge_requests", vim.tbl_extend("force", page_opts, { query = rest_query(args) })):await()
      if not page then
        return nil, rerr
      end
      local ctx = { origin = origin }
      return {
        items = vim.tbl_map(function(raw)
          return mr_model.from_rest(raw, ctx)
        end, page.items),
        next_cursor = page.next_cursor,
      }
    end

    local alias = MINE[scope]
    local vars = graphql_vars(args)
    vars.authored, vars.assigned, vars.reviewRequested = alias == "authored", alias == "assigned", alias == "reviewRequested"
    page_opts.what = "the current user"
    local page, gerr = graphql.page(args.host, "merge_requests_list_mine", vars, "currentUser." .. alias, page_opts):await()
    if not page then
      if gerr.kind == "not_found" then
        return nil, errors.new("auth", ("no signed-in user on %s (is a token configured?)"):format(args.host), {
          details = { host = args.host, scope = scope },
        })
      end
      return nil, gerr
    end
    return { items = map_nodes(page.items, { origin = origin }), next_cursor = page.next_cursor }
  end)
end

local list, list_all = common.lists(fetch_page)

--- One page of merge requests. Resolves with `gg.Page<gg.MergeRequest>`.
--- With `project` or `group`: that project's / group's MRs. Without: the
--- current user's (`scope` created_by_me, assigned_to_me, reviews_for_me),
--- or every MR the token can see (`scope = "all"`). One state per call.
---@param args gg.MergeRequestListArgs
---@param opts? { per_page?: integer, cursor?: string } per_page default 50
---@return gg.Task
function M.list(args, opts)
  return list(args, opts)
end

--- All merge requests up to `opts.limit`. Resolves with `{ items: gg.MergeRequest[], truncated: boolean }`.
---@param args gg.MergeRequestListArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.MergeRequest[]) }
---@return gg.Task
function M.list_all(args, opts)
  return list_all(args, opts)
end

local function get_mr(host, project, iid)
  return task.run(function()
    local path, perr = graphql.project_path(host, project):await()
    if not path then
      return nil, perr
    end
    local data, err = graphql.query(host, "merge_request_get", { fullPath = path, iid = tostring(iid) }):await()
    if err then
      return nil, err
    end
    local node, nerr = graphql.require(data, "project.mergeRequest", ("merge request %s!%s"):format(path, tostring(iid)))
    if not node then
      return nil, nerr
    end
    return mr_model.from_graphql(node, { origin = common.origin(host), project = path })
  end)
end

--- One merge request with description, diff refs and subscription state.
---@param args { host: string, project: string|integer, iid: integer }
---@return gg.Task resolves with gg.MergeRequest
function M.get(args)
  return common.run(args, { host = "host", project = "project", iid = "id" }, function()
    return get_mr(args.host, args.project, args.iid):await()
  end)
end

--- Merge requests by IID (any order, any state). Missing IIDs are absent.
---@param args { host: string, project: string|integer, iids: integer[] }
---@return gg.Task resolves with gg.MergeRequest[]
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

--- Most IIDs one `summaries` call accepts. diffStatsSummary calls Gitaly per
--- merge request and GraphQL limits query complexity, so batches stay small.
M.SUMMARIES_MAX = 20

-- summary field -> GraphQL field name in merge_request_summaries.graphql
local SUMMARY_FIELDS = { headPipeline = "head_pipeline", diffStatsSummary = "diff_stats" }

-- For a GraphQL error with partial data: the failed summary fields per node
-- index (0-based, as in the error paths), or nil when an error is not about
-- one of those fields (then the whole call fails).
local function failed_fields(err)
  local out = {}
  for _, e in ipairs(err.details and err.details.errors or {}) do
    local path = type(e.path) == "table" and e.path or {}
    local idx, field = path[4], SUMMARY_FIELDS[path[5]]
    if path[1] ~= "project" or path[2] ~= "mergeRequests" or path[3] ~= "nodes" or type(idx) ~= "number" or not field then
      return nil
    end
    out[idx] = out[idx] or {}
    out[idx][field] = true
  end
  return out
end

--- Head pipeline (stage statuses) and diff stats of merge requests, by IID,
--- in one request. Missing IIDs are absent. At most `M.SUMMARIES_MAX` IIDs
--- per call (more is a validation error). When GitLab reports an error for
--- one MR's pipeline or diff stats, that summary lists the field in `failed`
--- and the others are returned normally; any other error fails the call.
---@param args { host: string, project: string|integer, iids: integer[] }
---@return gg.Task resolves with gg.MergeRequestSummary[]
function M.summaries(args)
  return common.run(args, { host = "host", project = "project", iids = "ids" }, function()
    if #args.iids > M.SUMMARIES_MAX then
      return nil, common.invalid("iids", ("at most %d per call (got %d)"):format(M.SUMMARIES_MAX, #args.iids))
    end
    if #args.iids == 0 then
      return {}
    end
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local vars = { fullPath = path, iids = vim.tbl_map(tostring, args.iids), first = #args.iids }
    local data, err = graphql.query(args.host, "merge_request_summaries", vars):await()
    local failed = {}
    if err then
      local partial = err.kind == "graphql" and err.details and err.details.partial
      if partial == vim.NIL then
        partial = nil
      end
      failed = partial and failed_fields(err) or nil
      if not failed then
        return nil, err
      end
      data = partial
    end
    local conn, nerr = graphql.require(data, "project.mergeRequests", "project " .. path)
    if not conn then
      return nil, nerr
    end
    local ctx = { origin = common.origin(args.host), project = path }
    local out = {}
    for i, node in ipairs(type(conn.nodes) == "table" and conn.nodes or {}) do
      local s = mr_model.summary_from_graphql(node, ctx, failed[i - 1])
      if s then
        table.insert(out, s)
      end
    end
    return out
  end)
end

local function related_fetch(args, o)
  local err = common.check(args, { host = "host", project = "project", iid = "id" })
  if err then
    return task.failed(err)
  end
  return task.run(function()
    local path = ("/projects/%s/issues/%d/related_merge_requests"):format(rest.project(args.project), common.int(args.iid))
    local page, rerr = rest.page(args.host, path, {
      per_page = o.per_page,
      default_per_page = M.RELATED_PER_PAGE,
      cursor = o.cursor,
    }):await()
    if not page then
      return nil, rerr
    end
    local ctx = { origin = common.origin(args.host) }
    return {
      items = vim.tbl_map(function(raw)
        return mr_model.from_rest(raw, ctx)
      end, page.items),
      next_cursor = page.next_cursor,
    }
  end)
end

local related, related_all = common.lists(related_fetch)

--- One page of merge requests related to an issue. Resolves with `gg.Page<gg.MergeRequest>`.
---@param args { host: string, project: string|integer, iid: integer } the issue
---@param opts? { per_page?: integer, cursor?: string } per_page default 20
---@return gg.Task
function M.related_to_issue(args, opts)
  return related(args, opts)
end

--- All merge requests related to an issue, up to `opts.limit`.
---@param args { host: string, project: string|integer, iid: integer } the issue
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.MergeRequest[]) }
---@return gg.Task resolves with { items: gg.MergeRequest[], truncated: boolean }
function M.related_to_issue_all(args, opts)
  return related_all(args, opts)
end

-- Set draft status with the GraphQL mutation; resolves with the updated MR.
local function set_draft(host, project, iid, draft)
  return task.run(function()
    local path, perr = graphql.project_path(host, project):await()
    if not path then
      return nil, perr
    end
    local data, err = graphql.query(host, "merge_request_set_draft", { projectPath = path, iid = tostring(iid), draft = draft }):await()
    if err then
      return nil, err
    end
    local payload = data.mergeRequestSetDraft
    local perr2 = graphql.payload_error(payload, "MergeRequestSetDraft")
    if perr2 then
      return nil, perr2
    end
    local node, nerr = graphql.require(data, "mergeRequestSetDraft.mergeRequest", "updated merge request")
    if not node then
      return nil, nerr
    end
    return mr_model.from_graphql(node, { origin = common.origin(host), project = path })
  end)
end

---@class gg.MergeRequestCreateArgs
---@field host string
---@field project string|integer the target project
---@field source_branch string
---@field target_branch string
---@field title string
---@field description? string
---@field labels? string[]|string
---@field assignee_ids? integer[]
---@field reviewer_ids? integer[]
---@field milestone_id? integer
---@field remove_source_branch? boolean
---@field squash? boolean
---@field target_project_id? integer for MRs from a fork
---@field allow_collaboration? boolean
---@field draft? boolean create as a draft

--- Create a merge request (REST; draft via GraphQL).
---@param args gg.MergeRequestCreateArgs
---@return gg.Task resolves with gg.MergeRequest
function M.create(args)
  local spec = {
    host = "host",
    project = "project",
    source_branch = "string",
    target_branch = "string",
    title = "string",
    description = "text?",
    labels = "strings?",
    assignee_ids = "ids?",
    reviewer_ids = "ids?",
    milestone_id = "id?",
    remove_source_branch = "boolean?",
    squash = "boolean?",
    target_project_id = "id?",
    allow_collaboration = "boolean?",
    draft = "boolean?",
  }
  return common.run(args, spec, function()
    local body = {
      source_branch = args.source_branch,
      target_branch = args.target_branch,
      title = args.title,
      description = args.description,
      labels = common.csv(args.labels),
      assignee_ids = args.assignee_ids,
      reviewer_ids = args.reviewer_ids,
      milestone_id = common.int(args.milestone_id),
      remove_source_branch = args.remove_source_branch,
      squash = args.squash,
      target_project_id = common.int(args.target_project_id),
      allow_collaboration = args.allow_collaboration,
    }
    local res, err = rest.request(args.host, "POST", ("/projects/%s/merge_requests"):format(rest.project(args.project)), { body = body }):await()
    if err then
      return nil, err
    end
    local created = mr_model.from_rest(res.data, { origin = common.origin(args.host) })
    if args.draft then
      return set_draft(args.host, args.project, created.iid, true):await()
    end
    return created
  end)
end

---@class gg.MergeRequestUpdateArgs
---@field host string
---@field project string|integer
---@field iid integer
---@field title? string
---@field description? string
---@field state_event? "close"|"reopen"
---@field target_branch? string
---@field labels? string[]|string replaces all labels; {} or "" removes them
---@field add_labels? string[]|string
---@field remove_labels? string[]|string
---@field assignee_ids? integer[] {} unassigns everyone
---@field reviewer_ids? integer[] {} removes every reviewer
---@field milestone_id? integer|false false removes the milestone
---@field remove_source_branch? boolean
---@field squash? boolean
---@field discussion_locked? boolean
---@field allow_collaboration? boolean
---@field draft? boolean mark as draft / ready (GraphQL mutation)

local UPDATE_FIELDS = {
  "title",
  "description",
  "state_event",
  "target_branch",
  "labels",
  "add_labels",
  "remove_labels",
  "assignee_ids",
  "reviewer_ids",
  "milestone_id",
  "remove_source_branch",
  "squash",
  "discussion_locked",
  "allow_collaboration",
}

--- Update a merge request. At least one field besides host/project/iid.
---@param args gg.MergeRequestUpdateArgs
---@return gg.Task resolves with the updated gg.MergeRequest
function M.update(args)
  local spec = {
    host = "host",
    project = "project",
    iid = "id",
    title = "string?",
    description = "text?",
    state_event = common.enum(true, "close", "reopen"),
    target_branch = "string?",
    labels = "strings?",
    add_labels = "strings?",
    remove_labels = "strings?",
    assignee_ids = "ids?",
    reviewer_ids = "ids?",
    milestone_id = "id_or_false?",
    remove_source_branch = "boolean?",
    squash = "boolean?",
    discussion_locked = "boolean?",
    allow_collaboration = "boolean?",
    draft = "boolean?",
  }
  local err = common.check(args, spec)
  if err then
    return task.failed(err)
  end
  local body = {}
  for _, k in ipairs(UPDATE_FIELDS) do
    body[k] = args[k]
  end
  if next(body) == nil and args.draft == nil then
    return task.failed(common.invalid("title", "(or another field) is required: nothing to update"))
  end
  if args.labels ~= nil then
    body.labels = common.csv(args.labels)
  end
  body.add_labels = common.csv(args.add_labels)
  body.remove_labels = common.csv(args.remove_labels)
  for _, k in ipairs({ "assignee_ids", "reviewer_ids" }) do
    if args[k] ~= nil and #args[k] == 0 then
      body[k] = { 0 } -- documented: 0 unsets them all
    end
  end
  if args.milestone_id == false then
    body.milestone_id = 0
  elseif args.milestone_id ~= nil then
    body.milestone_id = common.int(args.milestone_id)
  end
  return task.run(function()
    local result
    if next(body) ~= nil then
      local path = ("/projects/%s/merge_requests/%d"):format(rest.project(args.project), common.int(args.iid))
      local res, rerr = rest.request(args.host, "PUT", path, { body = body }):await()
      if rerr then
        return nil, rerr
      end
      result = mr_model.from_rest(res.data, { origin = common.origin(args.host) })
    end
    if args.draft ~= nil then
      return set_draft(args.host, args.project, args.iid, args.draft):await()
    end
    return result
  end)
end

---@class gg.MergeRequestMergeArgs
---@field host string
---@field project string|integer
---@field iid integer
---@field sha? string must equal the source branch HEAD (required by some projects)
---@field squash? boolean
---@field should_remove_source_branch? boolean
---@field merge_commit_message? string
---@field squash_commit_message? string
---@field auto_merge? boolean merge when the checks pass

--- Merge a merge request (REST `PUT .../merge`). A 405 (cannot be merged),
--- 409 (SHA mismatch) or 422 (merge failed) is a `validation` error carrying
--- GitLab's message.
---@param args gg.MergeRequestMergeArgs
---@return gg.Task resolves with the merged gg.MergeRequest
function M.merge(args)
  local spec = {
    host = "host",
    project = "project",
    iid = "id",
    sha = "string?",
    squash = "boolean?",
    should_remove_source_branch = "boolean?",
    merge_commit_message = "string?",
    squash_commit_message = "string?",
    auto_merge = "boolean?",
  }
  return common.run(args, spec, function()
    local path = ("/projects/%s/merge_requests/%d/merge"):format(rest.project(args.project), common.int(args.iid))
    local body = {
      sha = args.sha,
      squash = args.squash,
      should_remove_source_branch = args.should_remove_source_branch,
      merge_commit_message = args.merge_commit_message,
      squash_commit_message = args.squash_commit_message,
      auto_merge = args.auto_merge,
    }
    if next(body) == nil then
      body = vim.empty_dict()
    end
    local res, err = rest.request(args.host, "PUT", path, { body = body }):await()
    if err then
      return nil, err
    end
    return mr_model.from_rest(res.data, { origin = common.origin(args.host) })
  end)
end

return M
