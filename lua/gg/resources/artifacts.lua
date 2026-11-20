--- Job artifacts: archive listings, and downloads always streamed to a file
--- or a callback.
---
--- Backend: REST (docs.gitlab.com/api/job_artifacts):
---   * GET /projects/:id/jobs/:job_id/artifacts                       (archive, or a report with file_type)
---   * GET /projects/:id/jobs/:job_id/artifacts/tree                  (archive entries, GitLab 18.8+)
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
local entry_model = require("gg.models.artifact_entry")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

M.DEFAULT_PER_PAGE = 100

--- Report types `download` accepts as `file_type` (docs.gitlab.com/api/job_artifacts).
M.FILE_TYPES = {
  "accessibility",
  "api_fuzzing",
  "archive",
  "browser_performance",
  "cluster_image_scanning",
  "cobertura",
  "codequality",
  "container_scanning",
  "cyclonedx",
  "dast",
  "dependency_scanning",
  "dotenv",
  "jacoco",
  "junit",
  "license_scanning",
  "load_performance",
  "lsif",
  "metrics",
  "performance",
  "requirements",
  "requirements_v2",
  "sarif",
  "sast",
  "secret_detection",
}

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

--- Download a job's artifacts archive to a file. With `file_type`, download
--- that report artifact instead (GitLab 19.4+; reports such as junit are
--- usually gzip-compressed and are written as served).
---@param args { host: string, project: string|integer, job_id: integer, output: string, file_type?: string }
---@return gg.Task resolves with gg.Download
function M.download(args)
  local spec = { host = "host", project = "project", job_id = "id", output = "string?", file_type = common.enum(true, unpack(M.FILE_TYPES)) }
  local err = common.check(args, spec) or check_sink(args or {}, true)
  if err then
    return task.failed(err)
  end
  local query = args.file_type and args.file_type ~= "archive" and { file_type = args.file_type } or nil
  return fetch(args, ("/projects/%s/jobs/%d/artifacts"):format(rest.project(args.project), common.int(args.job_id)), query)
end

---@class gg.ArtifactTreeArgs
---@field host string
---@field project string|integer
---@field job_id integer
---@field path? string directory to list, default the root
---@field recursive? boolean every entry below `path`, default false

local TREE_SPEC = { host = "host", project = "project", job_id = "id", path = "string?", recursive = "boolean?" }

local function fetch_tree_page(args, o)
  local err = common.check(args, TREE_SPEC)
  if err then
    return task.failed(err)
  end
  if args.path and not valid_artifact_path(args.path) then
    return task.failed(common.invalid("path", "must be a relative path inside the artifacts"))
  end
  return task.run(function()
    local path = ("/projects/%s/jobs/%d/artifacts/tree"):format(rest.project(args.project), common.int(args.job_id))
    local page, rerr = rest.page(args.host, path, {
      query = { path = args.path, recursive = args.recursive },
      per_page = o.per_page,
      default_per_page = M.DEFAULT_PER_PAGE,
      cursor = o.cursor,
    }):await()
    if not page then
      return nil, rerr
    end
    return { items = vim.tbl_map(entry_model.from_rest, page.items), next_cursor = page.next_cursor }
  end)
end

local tree, tree_all = common.lists(fetch_tree_page)

--- One page of the files and directories in a job's artifacts archive, read
--- from GitLab's metadata without downloading the archive (GitLab 18.8+; older
--- servers answer `not_found`). Resolves with `gg.Page<gg.ArtifactEntry>`.
---@param args gg.ArtifactTreeArgs
---@param opts? { per_page?: integer, cursor?: string } per_page default 100
---@return gg.Task
function M.tree(args, opts)
  return tree(args, opts)
end

--- Archive entries up to `opts.limit`. Resolves with `{ items: gg.ArtifactEntry[], truncated: boolean }`.
---@param args gg.ArtifactTreeArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.ArtifactEntry[]) }
---@return gg.Task
function M.tree_all(args, opts)
  return tree_all(args, opts)
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
