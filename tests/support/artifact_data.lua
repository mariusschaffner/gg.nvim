-- Test data for the artifacts view: the jobs behind docs/artifacts-design.png
-- (as gg.jobs.list_project maps them) and the entries of the main
-- pipeline's archive.
local date = require("gg.ui.lib.date")

local D = {}

D.HOST = "gitlab.example.com"
D.PROJECT = "my-group/infra-automation"
D.NOW_ISO = "2026-11-20T10:00:00Z"
D.NOW = date.parse_time(D.NOW_ISO)

local base_now = D.NOW

local function iso(offset)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", base_now + offset)
end

--- An ISO time `offset` seconds from D.NOW.
---@param offset integer
---@return string
function D.iso(offset)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", D.NOW + offset)
end

local H, DAY = 3600, 86400

local function pipeline(id, status, ref, ago, tag)
  return {
    id = id,
    iid = id - 4000,
    ref = ref,
    ref_path = (tag and "refs/tags/" or "refs/heads/") .. ref,
    tag = tag or false,
    status = status,
    created_at = iso(-ago),
    web_url = "https://gitlab.example.com/my-group/infra-automation/-/pipelines/" .. id,
  }
end

local function job(id, name, p, artifacts)
  local list = { { file_type = "trace", filename = "job.log", size = 2048, expired = false } }
  vim.list_extend(list, artifacts)
  return {
    id = id,
    name = name,
    status = "success",
    pipeline_id = p.id,
    pipeline = p,
    artifacts = list,
    web_url = "https://gitlab.example.com/my-group/infra-automation/-/jobs/" .. id,
    stage = name:match("^([^:]+)"),
  }
end

local function art(file_type, filename, size, expire_in, expired)
  return {
    file_type = file_type,
    filename = filename,
    size = size,
    expire_at = expire_in and iso(expire_in) or nil,
    expired = expired or false,
  }
end

--- The jobs, newest first (as GitLab lists them), with times relative to
--- `now` (default D.NOW).
---@param now? integer
---@return gg.Job[]
function D.jobs(now)
  base_now = now or D.NOW
  local p19 = pipeline(4819, "failed", "feat/oci-edge-lb", 1 * H)
  local p17 = pipeline(4817, "manual", "feat/rotate-tf-creds", 2 * H)
  local p15 = pipeline(4815, "success", "feat/dns01-wildcard", 3 * H)
  local p12 = pipeline(4812, "success", "main", 8 * H)
  local p08 = pipeline(4808, "success", "main", 1 * DAY)
  local p06 = pipeline(4806, "failed", "main", 2 * DAY)
  return {
    job(91060, "plan:all", p08, { art("archive", "artifacts.zip", 47104, 1 * DAY + H), { file_type = "metadata", filename = "metadata.gz", size = 300 } }),
    job(91052, "plan:edge", p17, { art("terraform", "plan.json", 1887436, 6 * DAY + H) }),
    job(91041, "test:checkov", p19, { art("sarif", "results.sarif", 317440, 6 * DAY + H) }),
    job(91040, "test:tflint", p19, { art("codequality", "tflint.json", 12288, 6 * DAY + H) }),
    job(91031, "test:unit", p15, { art("junit", "junit.xml.gz", 86016, 6 * DAY + H) }),
    job(91024, "build:package", p15, { art("archive", "artifacts.zip", 3355443, 6 * DAY + H) }),
    job(91022, "build:package", p12, { art("archive", "artifacts.zip", 13002342, nil), { file_type = "metadata", filename = "metadata.gz", size = 512 } }),
    job(91020, "build:vars", p12, { art("dotenv", "build.env", 512, 29 * DAY + H) }),
    job(90988, "build:package", p06, { art("archive", "artifacts.zip", 4096, -DAY, true) }),
  }
end

--- The archive of job 91022 (build:package on main), as archive entries.
---@return { path: string, size: integer }[]
function D.entries()
  return {
    { path = "dist/infra-automation-1.4.2.tar.gz", size = 10276044 },
    { path = "dist/checksums.sha256", size = 1024 },
    { path = "modules/edge-lb/main.tf", size = 4096 },
    { path = "modules/edge-lb/variables.tf", size = 2048 },
    { path = "modules/edge-lb/outputs.tf", size = 1024 },
    { path = "modules/object-storage/main.tf", size = 3072 },
    { path = "reports/terraform-docs.md", size = 38912 },
    { path = "reports/coverage.xml", size = 163840 },
    { path = "build.log", size = 317440 },
    { path = "VERSION", size = 6 },
  }
end

-- GraphQL ------------------------------------------------------------------

local function upper(s)
  return s and s:upper() or vim.NIL
end

--- A job as GitLab's GraphQL returns it (JobsListProject).
---@param j gg.Job
---@return table
function D.node(j)
  local p = j.pipeline
  return {
    id = "gid://gitlab/Ci::Build/" .. j.id,
    name = j.name,
    status = upper(j.status),
    allowFailure = false,
    manualJob = false,
    playable = false,
    retryable = true,
    cancelable = false,
    duration = 10,
    queuedDuration = 1,
    startedAt = p.created_at,
    finishedAt = p.created_at,
    createdAt = p.created_at,
    webPath = "/my-group/infra-automation/-/jobs/" .. j.id,
    refName = p.ref,
    shortSha = "a1b2c3d4",
    stage = { name = j.stage },
    artifacts = {
      nodes = vim.tbl_map(function(a)
        return { fileType = upper(a.file_type), name = a.filename, size = tostring(a.size), expireAt = a.expire_at or vim.NIL, expired = a.expired == true }
      end, j.artifacts),
      pageInfo = { hasNextPage = false },
    },
    pipeline = {
      id = "gid://gitlab/Ci::Pipeline/" .. p.id,
      iid = tostring(p.iid),
      path = "/my-group/infra-automation/-/pipelines/" .. p.id,
      ref = p.ref,
      refPath = p.ref_path,
      status = upper(p.status),
      createdAt = p.created_at,
    },
  }
end

local REST = "/api/v4/projects/my-group%2Finfra-automation/jobs/"

--- The fixtures the view needs: the jobs (one page), the project, the
--- tree of job 91022's archive, and file downloads.
---@param now integer
---@return table[]
function D.responses(now)
  local nodes = vim.tbl_map(D.node, D.jobs(now))
  local tree = vim.tbl_map(function(e)
    return { name = e.path:match("([^/]+)$"), path = e.path, type = "file", size = e.size, mode = "100644" }
  end, D.entries())
  table.insert(tree, 1, { name = "reports", path = "reports/", type = "directory", mode = "040755" })
  return {
    {
      ["repeat"] = true,
      request = { operation = "JobsListProject" },
      response = { body = { data = { project = { jobs = { nodes = nodes, pageInfo = { hasNextPage = false } } } } } },
    },
    {
      ["repeat"] = true,
      request = { operation = "ProjectGet" },
      response = { body = { data = { project = {
        id = "gid://gitlab/Project/7",
        name = "infra-automation",
        path = "infra-automation",
        fullPath = D.PROJECT,
        description = vim.NIL,
        webUrl = "https://" .. D.HOST .. "/" .. D.PROJECT,
        visibility = "private",
        archived = false,
        lastActivityAt = "2026-11-20T09:00:00Z",
        repository = { rootRef = "main" },
      } } } },
    },
    {
      ["repeat"] = true,
      request = { method = "GET", path = REST .. "91022/artifacts/tree" },
      response = { status = 200, body = tree },
    },
    {
      ["repeat"] = true,
      request = { method = "GET", path = REST .. "91022/artifacts/reports/terraform-docs.md" },
      response = { status = 200, body = "# Terraform docs\n\n| Name | Type |\n" },
    },
    {
      ["repeat"] = true,
      request = { method = "GET", path = REST .. "91020/artifacts", query = { file_type = "dotenv" } },
      response = { status = 200, body = "VERSION=1.4.2\n" },
    },
    {
      ["repeat"] = true,
      request = { method = "GET", path = REST .. "91031/artifacts", query = { file_type = "junit" } },
      response = { status = 200, body_base64 = "H4sIAAAAAAAAA8tIzcnJBwCGphA2BQAAAA==" },
    },
  }
end

--- Job 91024 (build:package on feat/dns01-wildcard) on a GitLab that cannot
--- list archives: the tree is 404, the archive itself downloads.
---@return table[]
function D.zip_responses()
  local bytes = D.zip({ { path = "dist/infra-automation-1.4.2-rc1.tar.gz", size = 3040870 }, { path = "build.log", size = 286720 }, { path = "VERSION", size = 6 } })
  return {
    { request = { method = "GET", path = REST .. "91024/artifacts/tree" }, response = { status = 404, body = { message = "404 Not Found" } } },
    { request = { method = "GET", path = REST .. "91024/artifacts" }, response = { status = 200, body_base64 = vim.base64.encode(bytes) } },
  }
end

D.REST = REST

-- little-endian bytes
local function le(v, n)
  local out = {}
  for _ = 1, n do
    table.insert(out, string.char(v % 256))
    v = math.floor(v / 256)
  end
  return table.concat(out)
end

D.le = le

--- A zip file's bytes holding `files` (`{ path, size }`; only the central
--- directory is real, the file data is a placeholder). With `zip64`, the
--- end record points to a Zip64 record and sizes over 4 GiB use the Zip64
--- extra field.
---@param files { path: string, size: integer }[]
---@param opts? { zip64?: boolean, comment?: string, prefix?: string }
---@return string bytes
---@return integer cd_offset
function D.zip(files, opts)
  opts = opts or {}
  local body = opts.prefix or "PK\3\4 local file data placeholder "
  local cd = {}
  for _, f in ipairs(files) do
    local big = f.size >= 0xFFFFFFFF
    local extra = big and (le(1, 2) .. le(8, 2) .. le(f.size, 8)) or ""
    table.insert(cd, table.concat({
      "PK\1\2",
      le(20, 2), le(20, 2), le(0, 2), le(0, 2), le(0, 2), le(0, 2), le(0, 4),
      le(big and 0xFFFFFFFF or f.size, 4), -- compressed
      le(big and 0xFFFFFFFF or f.size, 4), -- uncompressed
      le(#f.path, 2), le(#extra, 2), le(0, 2), le(0, 2), le(0, 2), le(0, 4), le(0, 4),
      f.path,
      extra,
    }))
  end
  local cd_bytes = table.concat(cd)
  local cd_offset = #body
  local comment = opts.comment or ""
  local tail
  if opts.zip64 then
    local rec_offset = cd_offset + #cd_bytes
    local rec = table.concat({ "PK\6\6", le(44, 8), le(45, 2), le(45, 2), le(0, 4), le(0, 4), le(#files, 8), le(#files, 8), le(#cd_bytes, 8), le(cd_offset, 8) })
    local loc = table.concat({ "PK\6\7", le(0, 4), le(rec_offset, 8), le(1, 4) })
    local eocd = table.concat({ "PK\5\6", le(0, 2), le(0, 2), le(0xFFFF, 2), le(0xFFFF, 2), le(0xFFFFFFFF, 4), le(0xFFFFFFFF, 4), le(#comment, 2), comment })
    tail = rec .. loc .. eocd
  else
    tail = table.concat({ "PK\5\6", le(0, 2), le(0, 2), le(#files, 2), le(#files, 2), le(#cd_bytes, 4), le(cd_offset, 4), le(#comment, 2), comment })
  end
  return body .. cd_bytes .. tail, cd_offset
end

return D
