--- Where artifacts go and how they are named: download paths, the buffer
--- name of an opened file, the path that `y` copies and the web URL that
--- `Y` copies. Pure.
---
--- Downloads land below `<download_dir>/gitlab/<project name>/<pipeline id>/`:
--- a file of an archive keeps its path inside the archive; a whole artifact
--- (an archive or a report) goes into a folder named after its job, so two
--- jobs of one pipeline never overwrite each other.
local M = {}

-- a job name as one safe path segment ("build:package" -> "build_package")
local function segment(s)
  local out = (s or ""):gsub("[^%w%.%-_]", "_")
  if out == "" or out == "." or out == ".." then
    return "_"
  end
  return out
end

M.segment = segment

--- The folder a pipeline's downloads go to.
---@param download_dir string already expanded (no "~")
---@param project string full path ("group/project")
---@param pipeline_id integer
---@return string
function M.base(download_dir, project, pipeline_id)
  local name = segment(tostring(project):match("([^/]+)$") or tostring(project))
  return ("%s/gitlab/%s/%d"):format(download_dir:gsub("[/\\]+$", ""), name, pipeline_id)
end

--- The download path of a node: a file keeps its archive path, a whole
--- artifact goes to `<job name>/<file name>`. nil for folders and pipelines.
---@param base string from `base`
---@param node gg.ui.ArtifactNode
---@return string|nil
function M.target(base, node)
  if node.kind == "file" then
    local parts = {}
    for seg in node.path:gmatch("[^/]+") do
      table.insert(parts, segment(seg))
    end
    return base .. "/" .. table.concat(parts, "/")
  end
  if node.kind == "artifact" then
    return ("%s/%s/%s"):format(base, segment(node.job.name), segment(node.name))
  end
  return nil
end

--- The name of the read-only buffer of an opened file.
---@param node gg.ui.ArtifactNode a file or a report artifact
---@return string
function M.buffer_name(node)
  return ("gitlab://artifacts/%d/%s"):format(node.job.id, node.kind == "file" and node.path or node.name)
end

--- The path `y` copies: the path inside the artifact, or the artifact's
--- file name. nil for pipelines.
---@param node gg.ui.ArtifactNode
---@return string|nil
function M.inner_path(node)
  if node.kind == "file" or node.kind == "dir" then
    return node.path
  end
  if node.kind == "artifact" then
    return node.name
  end
  return nil
end

-- percent-encode a path, keeping the slashes
local function encode(p)
  return (p:gsub("[^%w%-%._~/]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

--- The GitLab web page of a node: a file or folder in the archive browser,
--- an archive's browser, a report's download, or the pipeline.
---@param node gg.ui.ArtifactNode
---@return string|nil
function M.web_url(node)
  if node.kind == "pipeline" then
    return node.pipeline.web_url
  end
  local job_url = node.job and node.job.web_url
  if not job_url then
    return nil
  end
  if node.kind == "file" then
    return ("%s/artifacts/file/%s"):format(job_url, encode(node.path))
  end
  if node.kind == "dir" then
    return ("%s/artifacts/browse/%s"):format(job_url, encode(node.path:gsub("/$", "")))
  end
  if node.archive then
    return job_url .. "/artifacts/browse"
  end
  return ("%s/artifacts/download?file_type=%s"):format(job_url, node.artifact.file_type)
end

--- True when the first bytes of a file look binary (a NUL byte) or gzip.
---@param head string up to the first 8 KiB
---@return boolean binary
---@return boolean gzip
function M.sniff(head)
  local gzip = head:sub(1, 2) == "\31\139"
  return gzip or head:find("\0", 1, true) ~= nil, gzip
end

return M
