--- Chips and pills: short labels on a tinted background. Pure.
---
--- " label " for a label (its colour comes from `chip_hl`, see
--- `gg.ui.highlights.chip`) and " ● Open " for a state pill.
local text = require("gg.ui.lib.text")

local M = {}

---@alias gg.ui.ChipHl fun(color: string|nil): string

--- A label chip: `{ " name ", hl }`.
---@param label gg.Label
---@param chip_hl? gg.ui.ChipHl
---@return { [1]: string, [2]: string }
function M.label(label, chip_hl)
  local hl = chip_hl and chip_hl(label.color) or "GitlabChipFallback"
  return { " " .. text.clean(label.title or label.name or "?") .. " ", hl }
end

--- Label chips, wrapped into lines of at most `width` cells, one space
--- apart. A chip wider than a whole line is truncated.
---@param labels gg.Label[]
---@param width integer
---@param chip_hl? gg.ui.ChipHl
---@return { [1]: string, [2]: string|nil }[][] one segment list per line
function M.wrap(labels, width, chip_hl)
  local lines, cur, used = {}, {}, 0
  for _, l in ipairs(labels or {}) do
    local c = M.label(l, chip_hl)
    local w = text.width(c[1])
    if w > width then
      c = { text.truncate(c[1], width), c[2] }
      w = text.width(c[1])
    end
    if used > 0 and used + 1 + w > width then
      table.insert(lines, cur)
      cur, used = {}, 0
    end
    if used > 0 then
      table.insert(cur, { " ", nil })
      used = used + 1
    end
    table.insert(cur, c)
    used = used + w
  end
  if #cur > 0 then
    table.insert(lines, cur)
  end
  return lines
end

--- A state pill: `{ " ● Open ", hl }`.
---@param icon string
---@param label string
---@param hl string
---@return { [1]: string, [2]: string }
function M.pill(icon, label, hl)
  return { (" %s %s "):format(icon, label), hl }
end

return M
