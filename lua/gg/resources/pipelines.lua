--- CI pipelines.
---
--- Backends:
---   * list (project or merge request), get, graph: GraphQL. `get` and
---     `graph` look the pipeline up by its ID, so no REST lookup comes first.
---   * `graph` asks for the pipeline's merge request; on a GitLab version
---     without that field (a schema error) it retries without it. This is
---     decided per call; nothing is remembered.
---   * retry, cancel: REST (`POST /pipelines/:id/retry|cancel`).
local common = require("gg.resources.common")
local gid = require("gg.models.gid")
local graphql = require("gg.graphql.client")
local pipeline_model = require("gg.models.pipeline")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

M.DEFAULT_PER_PAGE = 50

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
}

local PROJECT_ONLY = { "scope", "ref", "sha", "source", "username" }

local function fetch_page(args, o)
  local err = common.check(args, LIST_SPEC)
  if err then
    return task.failed(err)
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
    local name, conn, what
    if args.mr_iid then
      vars.iid = tostring(args.mr_iid)
      name, conn, what = "pipelines_list_mr", "project.mergeRequest.pipelines", ("merge request %s!%d"):format(path, common.int(args.mr_iid))
    else
      vars.scope = args.scope and args.scope:upper() or nil
      vars.ref, vars.sha, vars.source, vars.username = args.ref, args.sha, args.source, args.username
      name, conn, what = "pipelines_list_project", "project.pipelines", "project " .. path
    end
    local page, gerr = graphql.page(args.host, name, vars, conn, {
      cursor = o.cursor,
      per_page = o.per_page,
      default_per_page = M.DEFAULT_PER_PAGE,
      what = what,
    }):await()
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
