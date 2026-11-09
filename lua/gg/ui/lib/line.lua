--- Build one buffer line from highlighted segments. Pure.
---
--- Layout happens in display cells; highlights are recorded as byte ranges
--- of the finished string, ready for `nvim_buf_set_extmark`.
local text = require("gg.ui.lib.text")

local M = {}

---@class gg.ui.Mark
---@field row integer 0-based buffer row (set by the caller)
---@field col integer 0-based byte column
---@field end_col integer exclusive byte column
---@field hl string highlight group

---@class gg.ui.Line
---@field private _parts string[]
---@field private _marks { col: integer, end_col: integer, hl: string }[]
---@field bytes integer byte length so far
---@field cells integer display width so far
local Line = {}
Line.__index = Line

--- A new, empty line.
---@return gg.ui.Line
function M.new()
  return setmetatable({ _parts = {}, _marks = {}, bytes = 0, cells = 0 }, Line)
end

--- Append `s`, highlighted with `hl` when given.
---@param s string
---@param hl? string
---@return gg.ui.Line self
function Line:add(s, hl)
  if s == "" then
    return self
  end
  if hl then
    table.insert(self._marks, { col = self.bytes, end_col = self.bytes + #s, hl = hl })
  end
  table.insert(self._parts, s)
  self.bytes = self.bytes + #s
  self.cells = self.cells + text.width(s)
  return self
end

--- Append spaces until the line is `cells` wide (no-op when already wider).
---@param cells integer
---@return gg.ui.Line self
function Line:pad_to(cells)
  if cells > self.cells then
    self:add(string.rep(" ", cells - self.cells))
  end
  return self
end

--- Append `s` truncated to `width` cells and padded to exactly `width`.
--- Only the text itself is highlighted, not the padding.
---@param s string
---@param width integer
---@param hl? string
---@return gg.ui.Line self
function Line:cell(s, width, hl)
  local start = self.cells
  self:add(text.truncate(s, width), hl)
  return self:pad_to(start + width)
end

---@class gg.ui.LineItem
---@field [1] string text
---@field [2]? string highlight group
---@field [3]? string a second group layered on the same text (e.g. bold)

--- Append space-separated items into exactly `width` cells. Items that do
--- not fit are dropped; the first one that does not fit is cut with "…"
--- when at least one cell is left for it.
---@param items gg.ui.LineItem[]
---@param width integer
---@return gg.ui.Line self
function Line:items(items, width)
  local start = self.cells
  local used = 0
  for _, it in ipairs(items) do
    local s = it[1]
    local sep = used > 0 and 1 or 0
    local w = text.width(s)
    local room = width - used - sep
    if room < 1 then
      break
    end
    if sep == 1 then
      self:add(" ")
    end
    local cut = w > room
    local at = self.bytes
    self:add(cut and text.truncate(s, room) or s, it[2])
    if it[3] and self.bytes > at then
      table.insert(self._marks, { col = at, end_col = self.bytes, hl = it[3] })
    end
    used = used + sep + math.min(w, room)
    if cut then
      break
    end
  end
  return self:pad_to(start + width)
end

--- The finished string and its highlights. Trailing padding is removed, but
--- never inside a highlight (a highlighted " All 12 " keeps its space).
---@return string
---@return { col: integer, end_col: integer, hl: string }[]
function Line:result()
  local full = table.concat(self._parts)
  local keep = 0
  for _, m in ipairs(self._marks) do
    keep = math.max(keep, m.end_col)
  end
  local s = full:sub(1, keep) .. full:sub(keep + 1):gsub("%s+$", "")
  local marks = {}
  for _, m in ipairs(self._marks) do
    if m.col < #s then
      table.insert(marks, { col = m.col, end_col = math.min(m.end_col, #s), hl = m.hl })
    end
  end
  return s, marks
end

return M
