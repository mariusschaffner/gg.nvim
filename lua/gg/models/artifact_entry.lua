--- An entry of a job's artifacts archive (REST `/jobs/:id/artifacts/tree`). Pure.
local util = require("gg.models.util")

local M = {}

---@class gg.ArtifactEntry
---@field name string file or directory name
---@field path string full path in the archive; directories end with "/"
---@field type "file"|"directory"
---@field size integer|nil bytes (files only)
---@field mode string|nil Unix mode in octal, e.g. "100644"

--- Map a REST tree entry.
---@param raw table|nil
---@return gg.ArtifactEntry|nil
function M.from_rest(raw)
  raw = util.value(raw)
  if type(raw) ~= "table" or type(util.value(raw.path)) ~= "string" then
    return nil
  end
  local path = util.value(raw.path)
  local kind = util.value(raw.type)
  if kind ~= "file" and kind ~= "directory" then
    kind = path:sub(-1) == "/" and "directory" or "file"
  end
  return {
    name = util.value(raw.name) or vim.fs.basename((path:gsub("/$", ""))),
    path = path,
    type = kind,
    size = tonumber(util.value(raw.size)),
    mode = util.value(raw.mode),
  }
end

return M
