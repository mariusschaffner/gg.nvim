--- A picker table (`gg.ui.Rendered`) inside a detail view's tab: the cursor
--- only rests on selectable rows, the selection survives re-renders and tab
--- switches, and `open_item` (`i` / `<CR>`) opens the row under the cursor.
local list_buffer = require("gg.ui.components.list_buffer")

local M = {}

---@class gg.ui.DetailTableOpts
---@field key_of fun(row: table): any|nil identity of a selectable row (nil: not a row)
---@field on_open fun(row: table)
---@field open_desc? string

---@class gg.ui.DetailTable
---@field host gg.ui.DetailHost
---@field tab string
---@field list gg.ui.ListBuffer
---@field rendered gg.ui.Rendered|nil
---@field selected any identity of the selected row
local Table = {}
Table.__index = Table

--- Mount a table in tab `tab` of `host`.
---@param host gg.ui.DetailHost
---@param tab string
---@param opts gg.ui.DetailTableOpts
---@return gg.ui.DetailTable
function M.new(host, tab, opts)
  local self = setmetatable({ host = host, tab = tab, opts = opts }, Table)
  local buf = host:buf(tab)
  self.list = list_buffer.new({
    buf = buf,
    win = host.content_float.win,
    on_select = function(lnum)
      if not self:_shown() then
        return
      end
      local row = lnum and self.rendered and self.rendered.rows[lnum]
      local id = row and opts.key_of(row)
      if id ~= nil then
        self.selected = id
      end
    end,
  })
  self.list:attach_navigation()
  host:map(tab, host.keys.open_item, function()
    local row = self:current()
    if row then
      opts.on_open(row)
    end
  end, opts.open_desc or "Open")
  return self
end

---@private
function Table:_shown()
  local win = self.host.content_float.win
  return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == self.list.buf
end

--- Draw `rendered`; the selected row stays selected when it is still there.
---@param rendered gg.ui.Rendered
function Table:set(rendered)
  self.rendered = rendered
  self.list:set(rendered)
  self:restore()
end

--- Put the cursor back on the selected row (the tab became visible).
function Table:restore()
  if not self:_shown() or not self.rendered then
    return
  end
  local target
  for _, lnum in ipairs(self.rendered.selectable) do
    local row = self.rendered.rows[lnum]
    if self.selected ~= nil and self.opts.key_of(row) == self.selected then
      target = lnum
      break
    end
  end
  self.list:select(target)
end

--- The row under the cursor (selectable rows only), or nil.
---@return table|nil
function Table:current()
  if not self:_shown() or not self.rendered then
    return nil
  end
  local lnum = self.list:current()
  return lnum and self.rendered.rows[lnum] or nil
end

return M
