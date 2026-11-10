--- A grid of one-cell characters with highlights, turned into document
--- lines. Pure. For drawings such as the pipeline graph, where text lands
--- at absolute columns.
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")

local M = {}

---@class gg.ui.Canvas
---@field width integer
---@field height integer
---@field private _rows { [1]: string, [2]: string|nil }[][]
local Canvas = {}
Canvas.__index = Canvas

--- A blank canvas.
---@param width integer
---@param height integer
---@return gg.ui.Canvas
function M.new(width, height)
  local rows = {}
  for r = 1, height do
    rows[r] = {}
    for c = 1, width do
      rows[r][c] = { " ", nil }
    end
  end
  return setmetatable({ width = width, height = height, _rows = rows }, Canvas)
end

--- Write `s` from (row, col), both 0-based, one character per cell; what
--- falls outside is dropped. Each character must be one cell wide.
---@param row integer
---@param col integer
---@param s string
---@param hl? string
function Canvas:put(row, col, s, hl)
  local cells = self._rows[row + 1]
  if not cells then
    return
  end
  local n = vim.fn.strchars(s)
  for i = 0, n - 1 do
    local c = col + i + 1
    if c >= 1 and c <= self.width then
      cells[c] = { vim.fn.strcharpart(s, i, 1), hl }
    end
  end
end

--- Give the cells (row, col .. col + len - 1) highlight `hl`, keeping
--- their characters.
---@param row integer
---@param col integer
---@param len integer
---@param hl string
function Canvas:paint(row, col, len, hl)
  local cells = self._rows[row + 1]
  if not cells then
    return
  end
  for c = col + 1, math.min(self.width, col + len) do
    if c >= 1 then
      cells[c][2] = hl
    end
  end
end

--- The character at (row, col), 0-based.
---@param row integer
---@param col integer
---@return string
function Canvas:at(row, col)
  local cells = self._rows[row + 1]
  return cells and cells[col + 1] and cells[col + 1][1] or " "
end

--- One row as a `gg.ui.Line`, runs of one highlight merged.
---@param row integer 0-based
---@return gg.ui.Line
function Canvas:line(row)
  local l = line.new()
  local run, hl = {}, false
  local function flush()
    if #run > 0 then
      l:add(table.concat(run), hl or nil)
    end
    run = {}
  end
  for _, c in ipairs(self._rows[row + 1] or {}) do
    if c[2] ~= hl then
      flush()
      hl = c[2]
    end
    table.insert(run, c[1])
  end
  flush()
  return l
end

--- The whole canvas as a document, each line after `pad`.
---@param pad? string
---@return gg.ui.Doc
function Canvas:doc(pad)
  pad = pad or ""
  local d = doc.new()
  for r = 0, self.height - 1 do
    local str, marks = self:line(r):result()
    local lnum = d:line(line.new():add(pad):add(str))
    for _, m in ipairs(marks) do
      table.insert(d.marks, { row = lnum - 1, col = #pad + m.col, end_col = #pad + m.end_col, hl = m.hl })
    end
  end
  return d
end

return M
