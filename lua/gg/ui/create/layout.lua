--- Geometry of a creation popup: a centred box over 70 % of the editor,
--- holding the title float, an optional row of field floats and the body
--- float, one empty row apart. Pure given `area`.
local M = {}

M.SHARE = 70 -- percent of the editor's width and height
M.MIN_WIDTH = 60 -- outer columns
M.MIN_HEIGHT = 14 -- outer rows
M.GAP = 1 -- empty rows between the floats
M.FIELD_GAP = 2 -- cells between two field floats
local BORDER = 2

---@class gg.ui.CreateRects
---@field title gg.ui.Rect
---@field fields gg.ui.Rect[] left to right
---@field body gg.ui.Rect

--- The popup's outer box: 70 % of the area, at least `MIN_WIDTH` x
--- `MIN_HEIGHT` (or the whole area when that is smaller), centred.
---@param area { columns: integer, lines: integer }
---@return { row: integer, col: integer, width: integer, height: integer }
function M.box(area)
  -- whole numbers: 170 * 0.7 is not 119 in floating point
  local width = math.max(math.floor(area.columns * M.SHARE / 100), M.MIN_WIDTH)
  local height = math.max(math.floor(area.lines * M.SHARE / 100), M.MIN_HEIGHT)
  width = math.max(BORDER + 1, math.min(width, area.columns))
  height = math.max(BORDER + 1, math.min(height, area.lines))
  return {
    row = math.max(0, math.floor((area.lines - height) / 2)),
    col = math.max(0, math.floor((area.columns - width) / 2)),
    width = width,
    height = height,
  }
end

--- Rects (inner sizes, outer positions) of the popup's floats for `nfields`
--- field floats (0 to 2) side by side with equal widths.
---@param nfields integer
---@param area { columns: integer, lines: integer }
---@return gg.ui.CreateRects
function M.rects(nfields, area)
  local box = M.box(area)
  local inner_w = box.width - BORDER
  local out = { title = { row = box.row, col = box.col, width = inner_w, height = 1 }, fields = {} }
  local row = box.row + 1 + BORDER + M.GAP
  if nfields > 0 then
    local outer = math.floor((box.width - M.FIELD_GAP * (nfields - 1)) / nfields)
    local col = box.col
    for i = 1, nfields do
      -- the last one takes what the division left over
      local w = i == nfields and (box.col + box.width - col) or outer
      out.fields[i] = { row = row, col = col, width = math.max(1, w - BORDER), height = 1 }
      col = col + w + M.FIELD_GAP
    end
    row = row + 1 + BORDER + M.GAP
  end
  local body_h = box.row + box.height - row - BORDER
  out.body = { row = row, col = box.col, width = inner_w, height = math.max(1, body_h) }
  return out
end

return M
