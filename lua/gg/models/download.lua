--- Result of a streamed download. Pure.
local M = {}

---@class gg.Download
---@field path string|nil the file written (when streamed to a file)
---@field bytes integer bytes written or delivered to the callback

--- Build a download result.
---@param path string|nil
---@param bytes integer|nil
---@return gg.Download
function M.new(path, bytes)
  return { path = path, bytes = bytes or 0 }
end

return M
