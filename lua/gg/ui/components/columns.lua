--- Column layout for the picker tables, in display cells. Pure.
---
--- A table is a row of columns, left to right. One column is flexible: it
--- takes whatever width is left (at least its `min`). When the window is too
--- narrow for that, `steps` are applied one after another (each on top of
--- the previous ones) until the flexible column fits; each step hides
--- columns or changes their widths. When even the last step does not fit,
--- the flexible column keeps its minimum and the line runs past the window.
local M = {}

---@class gg.ui.Column
---@field col integer 0-based display column
---@field width integer

---@class gg.ui.ColumnSpec
---@field name string
---@field width? integer fixed width (not for the flexible column)
---@field gap? integer blank cells before the column (default 0)
---@field flex? boolean takes the remaining width
---@field min? integer minimum width of the flexible column

---@class gg.ui.LayoutStep
---@field hide? string[] columns to hide
---@field width? table<string, integer> new widths

---@class gg.ui.LayoutSpec
---@field columns gg.ui.ColumnSpec[]
---@field steps? gg.ui.LayoutStep[]

-- the column widths and hidden set after `n` steps
local function state(spec, n)
  local widths, hidden = {}, {}
  for _, c in ipairs(spec.columns) do
    widths[c.name] = c.width
  end
  for i = 1, n do
    local step = spec.steps[i]
    for _, name in ipairs(step.hide or {}) do
      hidden[name] = true
    end
    for name, w in pairs(step.width or {}) do
      widths[name] = w
    end
  end
  return widths, hidden
end

-- cells taken by everything but the flexible column's own width
local function fixed(spec, widths, hidden)
  local sum = 0
  for _, c in ipairs(spec.columns) do
    if not hidden[c.name] then
      sum = sum + (c.gap or 0) + (c.flex and 0 or widths[c.name])
    end
  end
  return sum
end

--- The layout for a window `width` cells wide: `{ width, [name] = gg.ui.Column }`;
--- hidden columns are absent.
---@param width integer
---@param spec gg.ui.LayoutSpec
---@return table<string, gg.ui.Column|integer>
function M.layout(width, spec)
  local flex
  for _, c in ipairs(spec.columns) do
    if c.flex then
      flex = c
    end
  end
  local min = flex and flex.min or 0
  local steps = spec.steps or {}
  local widths, hidden
  for n = 0, #steps do
    widths, hidden = state(spec, n)
    if width - fixed(spec, widths, hidden) >= min then
      break
    end
  end
  if flex then
    widths[flex.name] = math.max(min, width - fixed(spec, widths, hidden))
  end
  local out = { width = width }
  local x = 0
  for _, c in ipairs(spec.columns) do
    if not hidden[c.name] then
      x = x + (c.gap or 0)
      out[c.name] = { col = x, width = widths[c.name] }
      x = x + widths[c.name]
    end
  end
  return out
end

return M
