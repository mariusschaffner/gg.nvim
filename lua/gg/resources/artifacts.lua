--- Job artifacts: downloads, always streamed to a file or a callback.
---
--- Backend: REST (docs.gitlab.com/api/job_artifacts):
---   * GET /projects/:id/jobs/:job_id/artifacts                       (archive)
---   * GET /projects/:id/jobs/:job_id/artifacts/*artifact_path        (one file)
---   * GET /projects/:id/jobs/artifacts/:ref_name/download?job=name   (archive, latest successful pipeline)
---   * GET /projects/:id/jobs/artifacts/:ref_name/raw/*artifact_path?job=name
---
--- Downloads may redirect to a CDN or object storage; transport follows the
--- redirect and drops the token for any other origin. There is no total
--- timeout, only the stall timeout. A partial file is removed on failure or
--- cancel, so `output` only ever holds a complete download.
local common = require("gg.resources.common")
local download = require("gg.models.download")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

-- "dir/sub file.txt" -> "dir/sub%20file.txt" (each segment encoded, slashes kept)
local function encode_path(p)
  local parts = {}
  for seg in p:gmatch("[^/]+") do
    table.insert(parts, rest.seg(seg))
  end
  return table.concat(parts, "/")
end

local function valid_artifact_path(p)
  return type(p) == "string" and p ~= "" and not p:find("%.%./") and not p:match("^%.%.$") and not p:match("/%.%.$")
end

local function fetch(args, path, query)
  return task.run(function()
    local res, err = rest.request(args.host, "GET", path, {
      query = query,
      output = args.output,
      on_chunk = args.on_chunk,
    }):await()
    if err then
      return nil, err
    end
    return download.new(args.output, res.bytes)
  end)
end

local function check_sink(args, file_only)
  if file_only then
    if args.output == nil then
      return common.invalid("output", "is required (archives are written to a file)")
    end
  elseif (args.output == nil) == (args.on_chunk == nil) then
    return common.invalid("output", "or args.on_chunk is required (exactly one): downloads are never buffered whole")
  end
  return nil
end

--- Download a job's artifacts archive to a file.
---@param args { host: string, project: string|integer, job_id: integer, output: string }
---@return gg.Task resolves with gg.Download
function M.download(args)
  local err = common.check(args, { host = "host", project = "project", job_id = "id", output = "string?" }) or check_sink(args or {}, true)
  if err then
    return task.failed(err)
  end
  return fetch(args, ("/projects/%s/jobs/%d/artifacts"):format(rest.project(args.project), common.int(args.job_id)))
end

--- Download one file from a job's artifacts.
---@param args { host: string, project: string|integer, job_id: integer, artifact_path: string, output?: string, on_chunk?: fun(data: string) }
---@return gg.Task resolves with gg.Download
function M.download_file(args)
  local spec = { host = "host", project = "project", job_id = "id", artifact_path = "string", output = "string?", on_chunk = "callback?" }
  local err = common.check(args, spec) or check_sink(args or {}, false)
  if err then
    return task.failed(err)
  end
  if not valid_artifact_path(args.artifact_path) then
    return task.failed(common.invalid("artifact_path", "must be a relative path inside the artifacts"))
  end
  return fetch(args, ("/projects/%s/jobs/%d/artifacts/%s"):format(rest.project(args.project), common.int(args.job_id), encode_path(args.artifact_path)))
end

--- Download the artifacts archive of the latest successful `job` on `ref`.
---@param args { host: string, project: string|integer, ref: string, job: string, output: string }
---@return gg.Task resolves with gg.Download
function M.download_ref(args)
  local err = common.check(args, { host = "host", project = "project", ref = "string", job = "string", output = "string?" }) or check_sink(args or {}, true)
  if err then
    return task.failed(err)
  end
  return fetch(args, ("/projects/%s/jobs/artifacts/%s/download"):format(rest.project(args.project), rest.seg(args.ref)), { job = args.job })
end

--- Download one artifact file of the latest successful `job` on `ref`.
---@param args { host: string, project: string|integer, ref: string, job: string, artifact_path: string, output?: string, on_chunk?: fun(data: string) }
---@return gg.Task resolves with gg.Download
function M.download_ref_file(args)
  local spec = { host = "host", project = "project", ref = "string", job = "string", artifact_path = "string", output = "string?", on_chunk = "callback?" }
  local err = common.check(args, spec) or check_sink(args or {}, false)
  if err then
    return task.failed(err)
  end
  if not valid_artifact_path(args.artifact_path) then
    return task.failed(common.invalid("artifact_path", "must be a relative path inside the artifacts"))
  end
  local path = ("/projects/%s/jobs/artifacts/%s/raw/%s"):format(rest.project(args.project), rest.seg(args.ref), encode_path(args.artifact_path))
  return fetch(args, path, { job = args.job })
end

return M
