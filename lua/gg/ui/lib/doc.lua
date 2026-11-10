--- A document: buffer lines, their highlights and per-line metadata. Pure.
---
--- The detail views render every pane (header, tab content, sidebar) into a
--- document first; `gg.ui.detail.host` writes it into a buffer.
local line = require("gg.ui.lib.line")
local text = require("gg.ui.lib.text")

local M = {}

---@class gg.ui.DocMark
---@field row integer 0-based
---@field col integer 0-based byte column
---@field end_col integer exclusive byte column
---@field hl string
---@field priority? integer

---@class gg.ui.Doc
---@field lines string[]
---@field marks gg.ui.DocMark[]
---@field line_hls { row: integer, hl: string }[] whole-line backgrounds (0-based rows)
---@field rows table<integer, table> 1-based line -> metadata given with the line
local Doc = {}
Doc.__index = Doc

--- A new, empty document.
---@return gg.ui.Doc
function M.new()
  return setmetatable({ lines = {}, marks = {}, line_hls = {}, rows = {} }, Doc)
end

--- Number of lines so far.
---@return integer
function Doc:count()
  return #self.lines
end

--- Append a finished `gg.ui.Line` (its highlights move to this row).
---@param l gg.ui.Line
---@param info? table metadata for this line (see `rows`)
---@return integer lnum 1-based
function Doc:line(l, info)
  local s, marks = l:result()
  local row = #self.lines
  table.insert(self.lines, s)
  for _, m in ipairs(marks) do
    table.insert(self.marks, { row = row, col = m.col, end_col = m.end_col, hl = m.hl })
  end
  if info then
    self.rows[row + 1] = info
  end
  return row + 1
end

--- Append one line of segments `{ text, hl }`.
---@param segs { [1]: string, [2]: string|nil }[]
---@param info? table
---@return integer lnum
function Doc:segments(segs, info)
  local l = line.new()
  for _, s in ipairs(segs) do
    l:add(s[1], s[2])
  end
  return self:line(l, info)
end

--- Append `s` as one line, highlighted with `hl`.
---@param s string
---@param hl? string
---@param info? table
---@return integer lnum
function Doc:text(s, hl, info)
  return self:line(line.new():add(text.clean(s), hl), info)
end

--- Append an empty line.
---@param info? table
---@return integer lnum
function Doc:blank(info)
  return self:text("", nil, info)
end

--- Give line `lnum` (1-based) a whole-line background.
---@param lnum integer
---@param hl string
function Doc:line_hl(lnum, hl)
  table.insert(self.line_hls, { row = lnum - 1, hl = hl })
end

--- Append every line of `other` (marks, backgrounds and metadata follow).
---@param other gg.ui.Doc
function Doc:append(other)
  local off = #self.lines
  for i, s in ipairs(other.lines) do
    self.lines[off + i] = s
  end
  for _, m in ipairs(other.marks) do
    table.insert(self.marks, { row = m.row + off, col = m.col, end_col = m.end_col, hl = m.hl, priority = m.priority })
  end
  for _, h in ipairs(other.line_hls) do
    table.insert(self.line_hls, { row = h.row + off, hl = h.hl })
  end
  for l, info in pairs(other.rows) do
    self.rows[l + off] = info
  end
end

--- Append `n` copies of an empty line.
---@param n integer
function Doc:pad(n)
  for _ = 1, n do
    self:blank()
  end
end

--- The plain line texts (for tests).
---@return string[]
function Doc:texts()
  return vim.deepcopy(self.lines)
end

return M
