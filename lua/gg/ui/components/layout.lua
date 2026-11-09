--- Geometry for floats stacked vertically over the whole editor.
local M = {}

---@class gg.ui.Rect
---@field row integer outer top row (border included)
---@field col integer outer left column
---@field width integer inner width
---@field height integer inner height

---@class gg.ui.StackItem
---@field height? integer fixed inner height
---@field fill? boolean takes the remaining height (one item)

--- The editor area floats may use: all columns, all lines but the command line.
---@return { columns: integer, lines: integer }
function M.editor()
  return { columns = vim.o.columns, lines = vim.o.lines - vim.o.cmdheight }
end

--- Rects for bordered floats stacked top to bottom, full width, `gap` blank
--- rows between them. Pure given `area`.
---@param items gg.ui.StackItem[]
---@param opts? { gap?: integer, area?: { columns: integer, lines: integer } }
---@return gg.ui.Rect[]
function M.stack(items, opts)
  opts = opts or {}
  local area = opts.area or M.editor()
  local gap = opts.gap or 1
  local border = 2
  local width = math.max(1, area.columns - border)
  local used = 0
  for i, item in ipairs(items) do
    used = used + border + (item.fill and 0 or (item.height or 1))
    if i > 1 then
      used = used + gap
    end
  end
  local fill_h = math.max(1, area.lines - used)
  local rects = {}
  local row = 0
  for i, item in ipairs(items) do
    if i > 1 then
      row = row + gap
    end
    local h = item.fill and fill_h or (item.height or 1)
    rects[i] = { row = row, col = 0, width = width, height = h }
    row = row + h + border
  end
  return rects
end

return M
