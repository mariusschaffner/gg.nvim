--- CI pipelines.
---
--- Backends:
---   * list (project or merge request), get, graph: GraphQL. `get` and
---     `graph` look the pipeline up by its ID, so no REST lookup comes first.
---   * Project lists ask for `refPath` (the tag flag) and the pipeline's
---     merge request; on a GitLab version without those fields (a schema
---     error) they retry without them (`tag` and `merge_request` stay nil).
---   * `graph` asks for the pipeline's merge request; on a GitLab version
---     without that field (a schema error) it retries without it. This is
---     decided per call; nothing is remembered.
---   * retry, cancel: REST (`POST /pipelines/:id/retry|cancel`).
---   * create: REST (`POST /projects/:id/pipeline`).
---   * config_variables: GraphQL `project.ciConfigVariables(ref:)`; REST has
---     no counterpart.
local common = require("gg.resources.common")
local gid = require("gg.models.gid")
local graphql = require("gg.graphql.client")
local pipeline_model = require("gg.models.pipeline")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

M.DEFAULT_PER_PAGE = 50
M.MAX_IDS = 20 -- GitLab's limit for `pipelines(ids:)`

local STATUSES = {
  "created",
  "waiting_for_resource",
  "preparing",
  "waiting_for_callback",
  "pending",
  "running",
  "failed",
  "success",
  "canceling",
  "canceled",
  "skipped",
  "manual",
  "scheduled",
}

---@class gg.PipelineListArgs
---@field host string
---@field project string|integer
---@field mr_iid? integer list the pipelines of this merge request instead
---@field status? string a pipeline status ("running", "failed", ...)
---@field scope? "running"|"pending"|"finished"|"branches"|"tags" project lists only
---@field ref? string project lists only
---@field sha? string project lists only
---@field source? string project lists only ("push", "schedule", ...)
---@field username? string project lists only
---@field ids? integer[] project lists only: just these pipelines (1 to 20 IDs)

local LIST_SPEC = {
  host = "host",
  project = "project",
  mr_iid = "id?",
  status = vim.tbl_extend("force", vim.deepcopy(STATUSES), { optional = true }),
  scope = common.enum(true, "running", "pending", "finished", "branches", "tags"),
  ref = "string?",
  sha = "string?",
  source = "string?",
  username = "string?",
  ids = "ids?",
}

local PROJECT_ONLY = { "scope", "ref", "sha", "source", "username", "ids" }

local function fetch_page(args, o)
  local err = common.check(args, LIST_SPEC)
  if err then
    return task.failed(err)
  end
  if args.ids and (#args.ids == 0 or #args.ids > M.MAX_IDS) then
    return task.failed(common.invalid("ids", ("must hold 1 to %d pipeline IDs"):format(M.MAX_IDS)))
  end
  if args.mr_iid then
    for _, k in ipairs(PROJECT_ONLY) do
      if args[k] ~= nil then
        return task.failed(common.invalid(k, "only applies to project pipeline lists (without args.mr_iid)"))
      end
    end
  end
  local origin = common.origin(args.host)
  return task.run(function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local vars = { fullPath = path, status = args.status and args.status:upper() or nil }
    local names, conn, what
    if args.mr_iid then
      vars.iid = tostring(args.mr_iid)
      names, conn, what = { "pipelines_list_mr" }, "project.mergeRequest.pipelines", ("merge request %s!%d"):format(path, common.int(args.mr_iid))
    else
      vars.scope = args.scope and args.scope:upper() or nil
      vars.ref, vars.sha, vars.source, vars.username = args.ref, args.sha, args.source, args.username
      if args.ids then
        vars.ids = vim.tbl_map(function(id)
          return gid.build("Ci::Pipeline", common.int(id))
        end, args.ids)
      end
      names, conn, what = { "pipelines_list_project", "pipelines_list_project_base" }, "project.pipelines", "project " .. path
    end
    local page, gerr
    for i, name in ipairs(names) do
      page, gerr = graphql.page(args.host, name, vars, conn, {
        cursor = o.cursor,
        per_page = o.per_page,
        default_per_page = M.DEFAULT_PER_PAGE,
        what = what,
      }):await()
      if not (gerr and i < #names and graphql.is_schema_error(gerr)) then
        break
      end
    end
    if not page then
      return nil, gerr
    end
    local ctx = { origin = origin, project = path }
    return {
      items = vim.tbl_map(function(n)
        return pipeline_model.from_graphql(n, ctx)
      end, page.items),
      next_cursor = page.next_cursor,
    }
  end)
end

local list, list_all = common.lists(fetch_page)

--- One page of pipelines, newest first. Resolves with `gg.Page<gg.Pipeline>`.
---@param args gg.PipelineListArgs
---@param opts? { per_page?: integer, cursor?: string } per_page default 50
---@return gg.Task
function M.list(args, opts)
  return list(args, opts)
end

--- All pipelines up to `opts.limit`. Resolves with `{ items: gg.Pipeline[], truncated: boolean }`.
---@param args gg.PipelineListArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Pipeline[]) }
---@return gg.Task
function M.list_all(args, opts)
  return list_all(args, opts)
end

local function query_pipeline(args, names)
  return task.run(function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local vars = { fullPath = path, id = gid.build("Ci::Pipeline", common.int(args.id)) }
    local data, err
    for i, name in ipairs(names) do
      data, err = graphql.query(args.host, name, vars):await()
      if not (err and i < #names and graphql.is_schema_error(err)) then
        break
      end
    end
    if err then
      return nil, err
    end
    local node, nerr = graphql.require(data, "project.pipeline", ("pipeline %d in %s"):format(common.int(args.id), path))
    if not node then
      return nil, nerr
    end
    return pipeline_model.from_graphql(node, { origin = common.origin(args.host), project = path })
  end)
end

--- One pipeline (summary stages).
---@param args { host: string, project: string|integer, id: integer }
---@return gg.Task resolves with gg.Pipeline
function M.get(args)
  return common.run(args, { host = "host", project = "project", id = "id" }, function()
    return query_pipeline(args, { "pipeline_get" }):await()
  end)
end

--- One pipeline with its stage -> group -> job graph (stage order and job
--- flags as GitLab returns them) and the merge request it ran for.
---@param args { host: string, project: string|integer, id: integer }
---@return gg.Task resolves with gg.Pipeline (stages[i].groups, stages[i].jobs)
function M.graph(args)
  return common.run(args, { host = "host", project = "project", id = "id" }, function()
    return query_pipeline(args, { "pipeline_graph", "pipeline_graph_base" }):await()
  end)
end

-- the project path when `project` is one (not an ID), for the model
local function path_of(project)
  return type(project) == "string" and not project:match("^%d+$") and project or nil
end

---@class gg.PipelineVariable
---@field key string
---@field value string
---@field type? "env_var"|"file" default "env_var"

---@class gg.PipelineCreateArgs
---@field host string
---@field project string|integer
---@field ref string a branch or tag
---@field variables? gg.PipelineVariable[]

local function check_variables(list)
  if list == nil then
    return nil
  end
  if next(list) ~= nil and not vim.islist(list) then
    return common.invalid("variables", "must be a list of { key, value, type? }")
  end
  for i, v in ipairs(list) do
    local where = ("variables[%d]"):format(i)
    if type(v) ~= "table" then
      return common.invalid(where, "must be a table { key, value, type? }")
    end
    if type(v.key) ~= "string" or v.key == "" then
      return common.invalid(where .. ".key", "must be a non-empty string")
    end
    if type(v.value) ~= "string" then
      return common.invalid(where .. ".value", "must be a string")
    end
    if v.type ~= nil and v.type ~= "env_var" and v.type ~= "file" then
      return common.invalid(where .. ".type", "must be one of: env_var, file")
    end
  end
  return nil
end

--- Run a new pipeline on a branch or tag (REST `POST /projects/:id/pipeline`).
---@param args gg.PipelineCreateArgs
---@return gg.Task resolves with gg.Pipeline
function M.create(args)
  local spec = { host = "host", project = "project", ref = "string", variables = "table?" }
  local err = common.check(args, spec) or check_variables(args.variables)
  if err then
    return task.failed(err)
  end
  return task.run(function()
    local body = { ref = args.ref }
    if args.variables and #args.variables > 0 then
      body.variables = vim.tbl_map(function(v)
        return { key = v.key, value = v.value, variable_type = v.type or "env_var" }
      end, args.variables)
    end
    local res, rerr = rest.request(args.host, "POST", ("/projects/%s/pipeline"):format(rest.project(args.project)), { body = body }):await()
    if rerr then
      return nil, rerr
    end
    return pipeline_model.from_rest(res.data, { origin = common.origin(args.host), project = path_of(args.project) })
  end)
end

---@class gg.PipelineConfigVariables
---@field ready boolean false while GitLab is still reading the CI configuration (ask again)
---@field variables gg.CiConfigVariable[]

--- The variables the CI configuration of `ref` declares for manually run
--- pipelines, with their defaults (GraphQL `project.ciConfigVariables`).
--- GitLab computes them in the background: the first call for a ref may
--- resolve with `ready = false` and no variables.
---@param args { host: string, project: string|integer, ref: string }
---@return gg.Task resolves with gg.PipelineConfigVariables
function M.config_variables(args)
  return common.run(args, { host = "host", project = "project", ref = "string" }, function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local data, err = graphql.query(args.host, "pipeline_config_variables", { fullPath = path, ref = args.ref }):await()
    if err then
      return nil, err
    end
    local project, nerr = graphql.require(data, "project", "project " .. path)
    if not project then
      return nil, nerr
    end
    local list = project.ciConfigVariables
    if type(list) ~= "table" then
      return { ready = false, variables = {} }
    end
    local out = {}
    for _, node in ipairs(list) do
      local v = pipeline_model.config_variable(node)
      if v then
        table.insert(out, v)
      end
    end
    return { ready = true, variables = out }
  end)
end

local function action(args, verb)
  return common.run(args, { host = "host", project = "project", id = "id" }, function()
    local path = ("/projects/%s/pipelines/%d/%s"):format(rest.project(args.project), common.int(args.id), verb)
    local res, err = rest.request(args.host, "POST", path):await()
    if err then
      return nil, err
    end
    local project = type(args.project) == "string" and not args.project:match("^%d+$") and args.project or nil
    return pipeline_model.from_rest(res.data, { origin = common.origin(args.host), project = project })
  end)
end

--- Retry the failed jobs of a pipeline (REST).
---@param args { host: string, project: string|integer, id: integer }
---@return gg.Task resolves with gg.Pipeline
function M.retry(args)
  return action(args, "retry")
end

--- Cancel a pipeline's running jobs (REST).
---@param args { host: string, project: string|integer, id: integer }
---@return gg.Task resolves with gg.Pipeline
function M.cancel(args)
  return action(args, "cancel")
end

return M
