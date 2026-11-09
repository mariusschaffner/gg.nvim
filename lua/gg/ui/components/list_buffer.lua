--- A read-only list buffer: writes rendered lines + extmarks, and keeps the
--- cursor on selectable lines only.
local M = {}

---@class gg.ui.ListContent
---@field lines string[]
---@field marks gg.ui.Mark[]
---@field virt_lines? { row: integer, chunks: gg.ui.Chunk[] }[]
---@field selectable integer[] 1-based line numbers

---@class gg.ui.ListBuffer
---@field buf integer
---@field win integer|nil
---@field ns integer static content namespace
---@field selectable integer[]
---@field private _is_sel table<integer, boolean>
---@field private _last integer last selected line
---@field private _on_select fun(lnum: integer|nil)|nil
---@field private _cursor_col fun(lnum: integer): integer
---@field private _moving boolean
local List = {}
List.__index = List

--- Wrap a buffer.
--- `cursor_col` gives the byte column the cursor rests on in a line
--- (default 0).
---@param opts { buf: integer, win?: integer, on_select?: fun(lnum: integer|nil), cursor_col?: fun(lnum: integer): integer }
---@return gg.ui.ListBuffer
function M.new(opts)
  local self = setmetatable({
    buf = opts.buf,
    win = opts.win,
    ns = vim.api.nvim_create_namespace("gg.ui.list"),
    selectable = {},
    _is_sel = {},
    _last = 0,
    _on_select = opts.on_select,
    _cursor_col = opts.cursor_col or function()
      return 0
    end,
    _moving = false,
  }, List)
  vim.bo[self.buf].modifiable = false
  return self
end

--- Replace the content. The cursor is not moved; call `select` after.
---@param content gg.ui.ListContent
function List:set(content)
  local buf = self.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
  for _, m in ipairs(content.marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, self.ns, m.row, m.col, { end_col = m.end_col, hl_group = m.hl })
  end
  for _, v in ipairs(content.virt_lines or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, self.ns, v.row, 0, { virt_lines = { v.chunks } })
  end
  self.selectable = content.selectable
  self._is_sel = {}
  for _, l in ipairs(content.selectable) do
    self._is_sel[l] = true
  end
end

--- Rewrite only lines `lnums` (1-based) from `content`, with their
--- highlights and virtual lines. The line count and the selectable lines
--- must be unchanged; the cursor is not moved.
---@param content gg.ui.ListContent
---@param lnums integer[]
function List:patch(content, lnums)
  local buf = self.buf
  if not vim.api.nvim_buf_is_valid(buf) or #lnums == 0 then
    return
  end
  local want = {}
  for _, l in ipairs(lnums) do
    want[l - 1] = true
  end
  -- clear first: replacing a line can move its extmarks onto the next one
  for _, l in ipairs(lnums) do
    vim.api.nvim_buf_clear_namespace(buf, self.ns, l - 1, l)
  end
  vim.bo[buf].modifiable = true
  for _, l in ipairs(lnums) do
    vim.api.nvim_buf_set_lines(buf, l - 1, l, false, { content.lines[l] })
  end
  vim.bo[buf].modifiable = false
  for _, m in ipairs(content.marks) do
    if want[m.row] then
      pcall(vim.api.nvim_buf_set_extmark, buf, self.ns, m.row, m.col, { end_col = m.end_col, hl_group = m.hl })
    end
  end
  for _, v in ipairs(content.virt_lines or {}) do
    if want[v.row] then
      pcall(vim.api.nvim_buf_set_extmark, buf, self.ns, v.row, 0, { virt_lines = { v.chunks } })
    end
  end
end

--- The selected line, or nil when nothing is selectable.
---@return integer|nil
function List:current()
  if not self.win or not vim.api.nvim_win_is_valid(self.win) or #self.selectable == 0 then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
  return self._is_sel[lnum] and lnum or nil
end

--- The selectable line nearest to `lnum` (ties go up).
---@param lnum integer
---@param dir? integer prefer this direction (1 down, -1 up)
---@return integer|nil
function List:nearest(lnum, dir)
  if #self.selectable == 0 then
    return nil
  end
  if self._is_sel[lnum] then
    return lnum
  end
  if dir == 1 then
    return self:_first_after(lnum) or self:_last_before(lnum)
  elseif dir == -1 then
    return self:_last_before(lnum) or self:_first_after(lnum)
  end
  local best, best_d
  for _, l in ipairs(self.selectable) do
    local d = math.abs(l - lnum)
    if best == nil or d < best_d then
      best, best_d = l, d
    end
  end
  return best
end

---@private
function List:_first_after(lnum)
  for _, l in ipairs(self.selectable) do
    if l > lnum then
      return l
    end
  end
end

---@private
function List:_last_before(lnum)
  for i = #self.selectable, 1, -1 do
    if self.selectable[i] < lnum then
      return self.selectable[i]
    end
  end
end

--- Put the cursor on `lnum` (snapped to the nearest selectable line).
---@param lnum integer|nil
function List:select(lnum)
  if not self.win or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local target = lnum and self:nearest(lnum) or self.selectable[1]
  self._moving = true
  if target then
    vim.api.nvim_win_set_cursor(self.win, { target, self._cursor_col(target) })
  else
    vim.api.nvim_win_set_cursor(self.win, { 1, 0 })
  end
  self._moving = false
  self._last = target or 0
  if self._on_select then
    self._on_select(target)
  end
end

--- Move `count` selectable lines down (negative: up), clamped at the ends.
---@param count integer
function List:move(count)
  if #self.selectable == 0 then
    return
  end
  local cur = self:current() or self:nearest(self._last > 0 and self._last or 1)
  local idx = 1
  for i, l in ipairs(self.selectable) do
    if l == cur then
      idx = i
      break
    end
  end
  idx = math.max(1, math.min(#self.selectable, idx + count))
  self:select(self.selectable[idx])
end

--- Map j/k/<Down>/<Up>/gg/G (buffer-local) and clamp the cursor on
--- `CursorMoved` so it never rests on a non-selectable line.
function List:attach_navigation()
  local buf = self.buf
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("j", function()
    self:move(vim.v.count1)
  end)
  map("<Down>", function()
    self:move(vim.v.count1)
  end)
  map("k", function()
    self:move(-vim.v.count1)
  end)
  map("<Up>", function()
    self:move(-vim.v.count1)
  end)
  map("gg", function()
    self:select(self.selectable[1])
  end)
  map("G", function()
    self:select(self.selectable[#self.selectable])
  end)
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = vim.api.nvim_create_augroup(("gg.ui.list.%d"):format(buf), { clear = true }),
    buffer = buf,
    callback = function()
      if self._moving or not self.win or not vim.api.nvim_win_is_valid(self.win) then
        return
      end
      local pos = vim.api.nvim_win_get_cursor(self.win)
      local lnum = pos[1]
      if self._is_sel[lnum] and pos[2] == self._cursor_col(lnum) then
        if lnum ~= self._last then
          self._last = lnum
          if self._on_select then
            self._on_select(lnum)
          end
        end
        return
      end
      local dir = lnum > self._last and 1 or (lnum < self._last and -1 or nil)
      self:select(self:nearest(lnum, dir) or self._last)
    end,
  })
end

return M
