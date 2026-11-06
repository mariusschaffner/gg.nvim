--- CI jobs: lists, details, logs and actions.
---
--- Backends:
---   * list (a pipeline's jobs), get: GraphQL (`pipeline.jobs`, `project.job`).
---   * trace (the job log): REST `/jobs/:id/trace`, always streamed to a file
---     or a callback, never buffered whole in Lua.
---   * retry, cancel, play: REST (`POST /jobs/:id/retry|cancel|play`).
---
--- Incremental logs: `offset` sends `Range: bytes=<offset>-` (atlas's
--- behaviour; the docs do not describe Range for this endpoint). A 206 is the
--- new tail; a 200 means the server ignored the range and sent the whole log
--- (`range_ignored = true`); a 416 means there are no new bytes.
local common = require("gg.resources.common")
local gid = require("gg.models.gid")
local graphql = require("gg.graphql.client")
local job_model = require("gg.models.job")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

M.DEFAULT_PER_PAGE = 100

local STATUSES = {
  "created",
  "waiting_for_resource",
  "preparing",
  "waiting_for_callback",
  "pending",
  "running",
  "success",
  "failed",
  "canceling",
  "canceled",
  "skipped",
  "manual",
  "scheduled",
}

---@class gg.JobListArgs
---@field host string
---@field project string|integer
---@field pipeline_id integer
---@field statuses? string[] job statuses to include
---@field include_retried? boolean default false (like REST)

local LIST_SPEC = {
  host = "host",
  project = "project",
  pipeline_id = "id",
  statuses = "strings?",
  include_retried = "boolean?",
}

local function fetch_page(args, o)
  local err = common.check(args, LIST_SPEC)
  if err then
    return task.failed(err)
  end
  for _, s in ipairs(common.list(args.statuses) or {}) do
    if not vim.tbl_contains(STATUSES, s) then
      return task.failed(common.invalid("statuses", "must contain only: " .. table.concat(STATUSES, ", ")))
    end
  end
  local origin = common.origin(args.host)
  return task.run(function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local vars = {
      fullPath = path,
      id = gid.build("Ci::Pipeline", common.int(args.pipeline_id)),
    }
    -- retried = false hides retried jobs; leaving it out returns them too
    if args.include_retried ~= true then
      vars.retried = false
    end
    if args.statuses then
      vars.statuses = vim.tbl_map(string.upper, common.list(args.statuses))
    end
    local page, gerr = graphql.page(args.host, "jobs_list", vars, "project.pipeline.jobs", {
      cursor = o.cursor,
      per_page = o.per_page,
      default_per_page = M.DEFAULT_PER_PAGE,
      what = ("pipeline %d in %s"):format(common.int(args.pipeline_id), path),
    }):await()
    if not page then
      return nil, gerr
    end
    return {
      items = vim.tbl_map(function(n)
        return job_model.from_graphql(n, { origin = origin })
      end, page.items),
      next_cursor = page.next_cursor,
    }
  end)
end

local list, list_all = common.lists(fetch_page)

--- One page of a pipeline's jobs. Resolves with `gg.Page<gg.Job>`.
---@param args gg.JobListArgs
---@param opts? { per_page?: integer, cursor?: string } per_page default 100
---@return gg.Task
function M.list(args, opts)
  return list(args, opts)
end

--- All of a pipeline's jobs up to `opts.limit`. Resolves with `{ items: gg.Job[], truncated: boolean }`.
---@param args gg.JobListArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Job[]) }
---@return gg.Task
function M.list_all(args, opts)
  return list_all(args, opts)
end

--- One job.
---@param args { host: string, project: string|integer, id: integer }
---@return gg.Task resolves with gg.Job
function M.get(args)
  return common.run(args, { host = "host", project = "project", id = "id" }, function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local data, err = graphql.query(args.host, "job_get", { fullPath = path, id = gid.build("Ci::Build", common.int(args.id)) }):await()
    if err then
      return nil, err
    end
    local node, nerr = graphql.require(data, "project.job", ("job %d in %s"):format(common.int(args.id), path))
    if not node then
      return nil, nerr
    end
    return job_model.from_graphql(node, { origin = common.origin(args.host) })
  end)
end

---@class gg.JobTraceArgs
---@field host string
---@field project string|integer
---@field id integer
---@field output? string write the log to this file
---@field on_chunk? fun(data: string) receive the log in chunks (on the main loop, in order)
---@field offset? integer only bytes from this offset (Range request)

---@class gg.JobTrace
---@field bytes integer bytes delivered
---@field range_ignored boolean|nil true when `offset` was sent but the whole log came back

--- Stream a job's log to `output` or `on_chunk` (exactly one is required).
---@param args gg.JobTraceArgs
---@return gg.Task resolves with gg.JobTrace
function M.trace(args)
  local spec = { host = "host", project = "project", id = "id", output = "string?", on_chunk = "callback?", offset = "count?" }
  local err = common.check(args, spec)
  if err then
    return task.failed(err)
  end
  if (args.output == nil) == (args.on_chunk == nil) then
    return task.failed(common.invalid("output", "or args.on_chunk is required (exactly one): logs are never buffered whole"))
  end
  return task.run(function()
    local headers = args.offset and args.offset > 0 and { Range = ("bytes=%d-"):format(args.offset) } or nil
    local path = ("/projects/%s/jobs/%d/trace"):format(rest.project(args.project), common.int(args.id))
    local res, rerr = rest.request(args.host, "GET", path, {
      headers = headers,
      output = args.output,
      on_chunk = args.on_chunk,
      accept = "text/plain",
    }):await()
    if rerr then
      if rerr.status == 416 then
        return { bytes = 0 }
      end
      return nil, rerr
    end
    return { bytes = res.bytes or 0, range_ignored = (headers ~= nil and res.status == 200) or nil }
  end)
end

local function action(args, verb, body)
  return task.run(function()
    local path = ("/projects/%s/jobs/%d/%s"):format(rest.project(args.project), common.int(args.id), verb)
    local res, err = rest.request(args.host, "POST", path, { body = body }):await()
    if err then
      return nil, err
    end
    return job_model.from_rest(res.data, { origin = common.origin(args.host) })
  end)
end

local ACTION_SPEC = { host = "host", project = "project", id = "id" }

--- Retry a job (REST). Resolves with the new gg.Job.
---@param args { host: string, project: string|integer, id: integer }
---@return gg.Task
function M.retry(args)
  return common.run(args, ACTION_SPEC, function()
    return action(args, "retry"):await()
  end)
end

--- Cancel a job (REST). Resolves with the gg.Job.
---@param args { host: string, project: string|integer, id: integer }
---@return gg.Task
function M.cancel(args)
  return common.run(args, ACTION_SPEC, function()
    return action(args, "cancel"):await()
  end)
end

--- Run a manual job (REST), optionally with variables.
---@param args { host: string, project: string|integer, id: integer, variables?: table<string, string> }
---@return gg.Task resolves with the gg.Job
function M.play(args)
  return common.run(args, { host = "host", project = "project", id = "id", variables = "table?" }, function()
    local body
    if args.variables then
      body = { job_variables_attributes = {} }
      local keys = vim.tbl_keys(args.variables)
      table.sort(keys)
      for _, k in ipairs(keys) do
        table.insert(body.job_variables_attributes, { key = k, value = tostring(args.variables[k]) })
      end
    end
    return action(args, "play", body):await()
  end)
end

return M
