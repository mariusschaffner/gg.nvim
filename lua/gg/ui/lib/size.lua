--- Human-readable byte sizes. Pure.
---
--- Base 1024: "6 B", "512 B", "12 KB", then one decimal from MB up:
--- "1.8 MB", "12.4 GB".
local M = {}

local UNITS = { "MB", "GB", "TB" }

--- `bytes` as a short size; "" for nil.
---@param bytes integer|nil
---@return string
function M.human(bytes)
  if type(bytes) ~= "number" then
    return ""
  end
  if bytes < 1024 then
    return ("%d B"):format(math.max(0, math.floor(bytes)))
  end
  local kb = math.floor(bytes / 1024 + 0.5)
  if kb < 1024 then
    return ("%d KB"):format(kb)
  end
  local v = bytes / 1024 / 1024
  for i, unit in ipairs(UNITS) do
    local shown = math.floor(v * 10 + 0.5) / 10
    if shown < 1024 or i == #UNITS then
      return ("%.1f %s"):format(shown, unit)
    end
    v = v / 1024
  end
  return ""
end

return M
