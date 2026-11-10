--- A set of floats that live and die together.
---
--- * Closing any member (or leaving to a window outside the group) closes
---   them all and returns to the window that was current before.
--- * `VimResized` recomputes the layout.
--- * The focused member's border uses the active highlight.
--- * A member with a right border label (`title_right`, `footer_right`) gets
---   its labels rebuilt when its width or its border colour changes.
--- * `hide` / `show` keep the group alive while another screen covers it
---   (see `gg.ui.components.stack`); while hidden, leaving the group does
---   not close it.
local float = require("gg.ui.components.float")

local M = {}

---@class gg.ui.GroupMemberSpec : gg.ui.FloatSpec
---@field name string
---@field border_hl? string this member's border (default: the group's)
---@field border_active_hl? string this member's border while focused
---@field winhighlight? string extra 'winhighlight' entries ("CursorLine:X")

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
---@field private _hidden boolean
---@field private _focus string|nil member focused when the group was hidden
---@field private _specs table<string, { focusable: boolean }>
---@field private _closed_au table<string, integer> WinClosed autocmd per member
local Group = {}
Group.__index = Group

local function winhighlight(border, extra)
  local s = ("FloatBorder:%s,FloatTitle:GitlabPickerTitle,FloatFooter:GitlabPickerFooter"):format(border)
  return extra and (s .. "," .. extra) or s
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
    _hidden = false,
    _specs = {},
    _closed_au = {},
    _labels = {},
  }, Group)
  self._augroup = vim.api.nvim_create_augroup(("gg.ui.group.%s"):format(tostring(self):match("0x%x+") or vim.uv.hrtime()), { clear = true })
  return self
end

--- Open a member float. Its rect comes from the layout.
---@param spec gg.ui.GroupMemberSpec
---@return gg.ui.Float
function Group:add(spec)
  spec.rect = spec.rect or self._layout()[spec.name]
  spec.hide = self._hidden or nil
  spec.label_hl = spec.border_hl or self._border.inactive
  local f = float.open(spec)
  self.members[spec.name] = f
  self._labels[spec.name] = { title = spec.title, title_right = spec.title_right, footer = spec.footer, footer_right = spec.footer_right }
  self._specs[spec.name] = { focusable = spec.focusable ~= false, winhl = spec.winhighlight }
  table.insert(self._order, spec.name)
  self._borders = self._borders or {}
  self._borders[f.win] = {
    active = spec.border_active_hl or self._border.active,
    inactive = spec.border_hl or self._border.inactive,
  }
  vim.api.nvim_set_option_value("winhighlight", winhighlight(self._borders[f.win].inactive, spec.winhighlight), { win = f.win })
  self:_watch(spec.name, f)
  return f
end

--- Close one member without closing the group (e.g. a side panel that does
--- not fit any more). A no-op for an unknown name.
---@param name string
function Group:remove(name)
  local f = self.members[name]
  if not f then
    return
  end
  pcall(vim.api.nvim_del_autocmd, self._closed_au[name])
  self._closed_au[name] = nil
  self.members[name] = nil
  self._specs[name] = nil
  self._labels[name] = nil
  for i, n in ipairs(self._order) do
    if n == name then
      table.remove(self._order, i)
      break
    end
  end
  if vim.api.nvim_win_is_valid(f.win) then
    pcall(vim.api.nvim_win_close, f.win, true)
  end
end

---@private
function Group:_watch(name, f)
  self._closed_au[name] = vim.api.nvim_create_autocmd("WinClosed", {
    group = self._augroup,
    pattern = tostring(f.win),
    callback = function()
      vim.schedule(function()
        self:close()
      end)
    end,
  })
  if not self._watching then
    self._watching = true
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
          if self._closed or self._hidden then
            return
          end
          local cur = vim.api.nvim_get_current_win()
          if self:name_of(cur) or (self._guests and self._guests[cur]) then
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

--- Let window `win` (an overlay such as a field editor) take the focus
--- without the group closing. `false` forgets it again.
---@param win integer
---@param allowed? boolean default true
function Group:allow(win, allowed)
  self._guests = self._guests or {}
  self._guests[win] = allowed ~= false or nil
end

--- Draw member `name`'s border in `hl` (focused or not) until it is reset
--- with nil, e.g. while its content is being edited.
---@param name string
---@param hl string|nil
function Group:set_border(name, hl)
  self._border_override = self._border_override or {}
  self._border_override[name] = hl
  self:_paint()
end

-- the border group member `name` is drawn in right now
---@private
function Group:_border_of(name)
  local f = self.members[name]
  local b = self._borders[f.win]
  local focused = f.win == vim.api.nvim_get_current_win()
  return (self._border_override and self._border_override[name]) or (focused and b.active or b.inactive)
end

-- rebuild the left + right border labels of `name` for its width and colour
---@private
function Group:_relabel(name)
  local labels, f = self._labels[name], self.members[name]
  -- a member without a right label keeps whatever its owner set on the window
  if not (labels and (labels.title_right or labels.footer_right) and f and vim.api.nvim_win_is_valid(f.win)) then
    return
  end
  local hl = self:_border_of(name)
  local width = vim.api.nvim_win_get_width(f.win)
  local key = ("%s|%d|%s"):format(hl, width, tostring(labels.rev))
  if labels.drawn == key then
    return
  end
  labels.drawn = key
  float.set_text(f.win, {
    title = labels.title,
    title_right = labels.title_right,
    footer = labels.footer,
    footer_right = labels.footer_right,
    label_hl = hl,
  })
end

--- Set border labels of member `name`: any of `title`, `title_right`,
--- `footer`, `footer_right` (the others stay). They are kept across
--- resizes and focus changes.
---@param name string
---@param labels { title?: string|gg.ui.Chunk[], title_right?: string|gg.ui.Chunk[], footer?: string|gg.ui.Chunk[], footer_right?: string|gg.ui.Chunk[] }
function Group:set_labels(name, labels)
  if not self.members[name] then
    return
  end
  local cur = self._labels[name] or {}
  for _, k in ipairs({ "title", "title_right", "footer", "footer_right" }) do
    if labels[k] ~= nil then
      cur[k] = labels[k]
    end
  end
  cur.rev = (cur.rev or 0) + 1
  self._labels[name] = cur
  self:_relabel(name)
end

---@private
function Group:_paint()
  for name, f in pairs(self.members) do
    if vim.api.nvim_win_is_valid(f.win) then
      vim.api.nvim_set_option_value("winhighlight", winhighlight(self:_border_of(name), self._specs[name].winhl), { win = f.win })
      self:_relabel(name)
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
      float.update(f.win, rects[name], { hide = self._hidden, focusable = self._specs[name].focusable })
      self:_relabel(name)
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

---@return boolean
function Group:is_hidden()
  return self._hidden
end

--- Hide every member (the windows and buffers stay). Remembers the focused
--- member for `show`.
function Group:hide()
  if self._closed or self._hidden then
    return
  end
  self._hidden = true
  self._focus = self:name_of(vim.api.nvim_get_current_win()) or self._focus
  for _, name in ipairs(self._order) do
    float.set_hidden(self.members[name].win, true)
  end
end

--- Show the members again, re-run the layout (the editor may have been
--- resized meanwhile) and focus the member that had focus (or `focus`).
---@param focus? string
function Group:show(focus)
  if self._closed or not self._hidden then
    return
  end
  self._hidden = false
  for _, name in ipairs(self._order) do
    float.set_hidden(self.members[name].win, false)
  end
  self:relayout()
  self:focus(focus or self._focus or self._order[1])
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
