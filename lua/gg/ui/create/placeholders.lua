--- `‹placeholder›` spans in the text of a creation popup. Pure.
---
--- A placeholder marks something still to be written. `<C-n>` / `<C-p>`
--- jump between them and select the span, so typing replaces it.
local M = {}

M.OPEN = "‹"
M.CLOSE = "›"

---@class gg.ui.Placeholder
---@field row integer 1-based line
---@field col integer 0-based byte column of `‹`
---@field end_col integer 0-based byte column after `›`
---@field text string the name between the marks

--- Wrap `name` in the placeholder marks.
---@param name string
---@return string
function M.wrap(name)
  return M.OPEN .. name .. M.CLOSE
end

--- True when `s` is exactly one placeholder.
---@param s string
---@return boolean
function M.is(s)
  return s:sub(1, #M.OPEN) == M.OPEN and s:sub(-#M.CLOSE) == M.CLOSE and not s:sub(#M.OPEN + 1, -#M.CLOSE - 1):find(M.CLOSE, 1, true)
end

--- Every placeholder in `lines`, in reading order.
---@param lines string[]
---@return gg.ui.Placeholder[]
function M.find(lines)
  local out = {}
  for row, line in ipairs(lines) do
    local from = 1
    while true do
      local s = line:find(M.OPEN, from, true)
      if not s then
        break
      end
      local e = line:find(M.CLOSE, s + #M.OPEN, true)
      if not e then
        break
      end
      local stop = e + #M.CLOSE - 1
      table.insert(out, { row = row, col = s - 1, end_col = stop, text = line:sub(s + #M.OPEN, e - 1) })
      from = stop + 1
    end
  end
  return out
end

--- The placeholder after (`dir` 1) or before (-1) the position, wrapping
--- around. A placeholder the cursor is inside of counts as the current one
--- and is skipped. Nil without placeholders.
---@param spans gg.ui.Placeholder[]
---@param row integer 1-based
---@param col integer 0-based byte column
---@param dir integer 1 or -1
---@return gg.ui.Placeholder|nil
function M.step(spans, row, col, dir)
  if #spans == 0 then
    return nil
  end
  if dir >= 0 then
    for _, p in ipairs(spans) do
      if p.row > row or (p.row == row and p.col > col) then
        return p
      end
    end
    return spans[1]
  end
  for i = #spans, 1, -1 do
    local p = spans[i]
    if p.row < row or (p.row == row and p.end_col <= col) then
      return p
    end
  end
  return spans[#spans]
end

return M
