--- A set of floats that live and die together.
---
--- * Closing any member (or leaving to a window outside the group) closes
---   them all and returns to the window that was current before.
--- * `VimResized` recomputes the layout.
--- * The focused member's border uses the active highlight.
local float = require("gg.ui.components.float")

local M = {}

---@class gg.ui.GroupMemberSpec : gg.ui.FloatSpec
---@field name string
---@field border_hl? string this member's border (default: the group's)
---@field border_active_hl? string this member's border while focused

---@class gg.ui.FloatGroup
---@field members table<string, gg.ui.Float>
---@field private _order string[]
---@field private _layout fun(): table<string, gg.ui.Rect>
---@field private _augroup integer
---@field private _prev_win integer
---@field private _closed boolean
---@field private _on_close fun()[]
---@field private _on_resize fun()[]
---@field private _border { active: string, inactive: string }
---@field private _borders table<integer, { active: string, inactive: string }> per member window
local Group = {}
Group.__index = Group

local function winhighlight(border)
  return ("FloatBorder:%s,FloatTitle:GitlabPickerTitle,FloatFooter:GitlabPickerFooter"):format(border)
end

--- Create a group. `layout()` returns a rect per member name.
---@param opts { layout: fun(): table<string, gg.ui.Rect>, border_hl?: string, border_active_hl?: string }
---@return gg.ui.FloatGroup
function M.new(opts)
  local self = setmetatable({
    members = {},
    _order = {},
    _layout = opts.layout,
    _prev_win = vim.api.nvim_get_current_win(),
    _closed = false,
    _on_close = {},
    _on_resize = {},
    _border = { active = opts.border_active_hl or "GitlabPickerBorderActive", inactive = opts.border_hl or "GitlabPickerBorder" },
  }, Group)
  self._augroup = vim.api.nvim_create_augroup(("gg.ui.group.%s"):format(tostring(self):match("0x%x+") or vim.uv.hrtime()), { clear = true })
  return self
end

--- Open a member float. Its rect comes from the layout.
---@param spec gg.ui.GroupMemberSpec
---@return gg.ui.Float
function Group:add(spec)
  spec.rect = self._layout()[spec.name]
  local f = float.open(spec)
  self.members[spec.name] = f
  table.insert(self._order, spec.name)
  self._borders = self._borders or {}
  self._borders[f.win] = {
    active = spec.border_active_hl or self._border.active,
    inactive = spec.border_hl or self._border.inactive,
  }
  vim.api.nvim_set_option_value("winhighlight", winhighlight(self._borders[f.win].inactive), { win = f.win })
  self:_watch(f)
  return f
end

---@private
function Group:_watch(f)
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self._augroup,
    pattern = tostring(f.win),
    callback = function()
      vim.schedule(function()
        self:close()
      end)
    end,
  })
  if #self._order == 1 then
    vim.api.nvim_create_autocmd("VimResized", {
      group = self._augroup,
      callback = function()
        self:relayout()
      end,
    })
    vim.api.nvim_create_autocmd("WinEnter", {
      group = self._augroup,
      callback = function()
        vim.schedule(function()
          if self._closed then
            return
          end
          if self:name_of(vim.api.nvim_get_current_win()) then
            self:_paint()
          else
            -- focus moved outside the group: close, but stay where the user went
            self:close({ restore = false })
          end
        end)
      end,
    })
  end
end

--- The member name of window `win`, or nil.
---@param win integer
---@return string|nil
function Group:name_of(win)
  for name, f in pairs(self.members) do
    if f.win == win then
      return name
    end
  end
  return nil
end

---@private
function Group:_paint()
  local cur = vim.api.nvim_get_current_win()
  for _, f in pairs(self.members) do
    if vim.api.nvim_win_is_valid(f.win) then
      local b = self._borders[f.win]
      local hl = f.win == cur and b.active or b.inactive
      vim.api.nvim_set_option_value("winhighlight", winhighlight(hl), { win = f.win })
    end
  end
end

--- Focus a member window.
---@param name string
function Group:focus(name)
  local f = self.members[name]
  if f and vim.api.nvim_win_is_valid(f.win) then
    vim.api.nvim_set_current_win(f.win)
    self:_paint()
  end
end

--- Recompute the layout (after `VimResized`) and notify `on_resize`.
function Group:relayout()
  if self._closed then
    return
  end
  local rects = self._layout()
  for name, f in pairs(self.members) do
    if rects[name] then
      float.update(f.win, rects[name])
    end
  end
  for _, fn in ipairs(self._on_resize) do
    fn()
  end
end

--- Run `fn` after every relayout.
---@param fn fun()
function Group:on_resize(fn)
  table.insert(self._on_resize, fn)
end

--- Run `fn` once when the group closes.
---@param fn fun()
function Group:on_close(fn)
  table.insert(self._on_close, fn)
end

---@return boolean
function Group:is_closed()
  return self._closed
end

--- Close every member, restore the previous window (unless
--- `opts.restore == false`), run `on_close` hooks.
---@param opts? { restore?: boolean }
function Group:close(opts)
  if self._closed then
    return
  end
  self._closed = true
  pcall(vim.api.nvim_del_augroup_by_id, self._augroup)
  for _, name in ipairs(self._order) do
    local f = self.members[name]
    if f and vim.api.nvim_win_is_valid(f.win) then
      pcall(vim.api.nvim_win_close, f.win, true)
    end
  end
  if not (opts and opts.restore == false) and vim.api.nvim_win_is_valid(self._prev_win) then
    pcall(vim.api.nvim_set_current_win, self._prev_win)
  end
  for _, fn in ipairs(self._on_close) do
    pcall(fn)
  end
end

return M
