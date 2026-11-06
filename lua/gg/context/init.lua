--- Context: turn remote URLs (and, from 5.2, web URLs and short references)
--- into explicit hosts and project paths. Pure; never calls git.
local remote = require("gg.context.remote")

local M = {}

--- Parse a git remote URL. See `gg.context.remote.parse`.
---@param url string
---@param opts? gg.ContextOptions
---@return gg.Remote|nil
---@return gg.Error|nil
function M.parse(url, opts)
  return remote.parse(url, opts)
end

return M
