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

M.SIDEBAR_WIDTH = 34 -- outer, border included
M.SIDEBAR_GAP = 1
M.NARROW = 100 -- below this many columns there is no sidebar
M.HEADER_MAX = 0.55 -- the header takes at most this share of the height

--- True when a detail view has room for its sidebar.
---@param area? { columns: integer, lines: integer }
---@return boolean
function M.has_sidebar(area)
  area = area or M.editor()
  return area.columns >= M.NARROW
end

--- The largest header height (inner) for `area`.
---@param area? { columns: integer, lines: integer }
---@return integer
function M.header_max(area)
  area = area or M.editor()
  return math.max(1, math.floor((area.lines - 4) * M.HEADER_MAX))
end

--- Rects for a detail view: the header across the top, the content below
--- it and, when `sidebar` is set and the editor is wide enough, a sidebar to
--- the right of the content. Pure given `area`.
---@param opts { header_h: integer, sidebar?: boolean, area?: { columns: integer, lines: integer } }
---@return { header: gg.ui.Rect, content: gg.ui.Rect, sidebar?: gg.ui.Rect }
function M.detail(opts)
  local area = opts.area or M.editor()
  local border = 2
  local header_h = math.max(1, math.min(opts.header_h, M.header_max(area)))
  local full = math.max(1, area.columns - border)
  local below = header_h + border
  local content_h = math.max(1, area.lines - below - border)
  local out = {
    header = { row = 0, col = 0, width = full, height = header_h },
  }
  if opts.sidebar and M.has_sidebar(area) then
    local side_col = area.columns - M.SIDEBAR_WIDTH
    out.content = { row = below, col = 0, width = math.max(1, side_col - M.SIDEBAR_GAP - border), height = content_h }
    out.sidebar = { row = below, col = side_col, width = M.SIDEBAR_WIDTH - border, height = content_h }
  else
    out.content = { row = below, col = 0, width = full, height = content_h }
  end
  return out
end

return M
