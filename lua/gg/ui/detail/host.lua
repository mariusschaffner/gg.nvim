--- The windows of one detail view: a header across the top, the content
--- below it and an optional sidebar on the right (only when the editor has
--- at least `layout.NARROW` columns).
---
--- Every tab has its own buffer, so a tab keeps its cursor and its own
--- keymaps; switching tabs shows another buffer in the content window. The
--- host writes rendered documents (`gg.ui.lib.doc`) into the buffers and
--- maps the keys every detail view shares: back (`q`), close all (`Q`),
--- reload (`R`) and the tab keys.
---
--- A detail view is a screen of the picker's stack: `host.screen` is what
--- the view hands to `stack:push`.
local float = require("gg.ui.components.float")
local doc = require("gg.ui.lib.doc")
local float_group = require("gg.ui.components.float_group")
local header = require("gg.ui.detail.header")
local hint = require("gg.ui.lib.hint")
local layout = require("gg.ui.components.layout")

local M = {}

local CONTENT_WIN_OPTS = {
  wrap = false,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  spell = false,
  list = false,
  cursorline = true,
}

local SIDE_WIN_OPTS = {
  wrap = false,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  spell = false,
  list = false,
  cursorline = false,
}

---@class gg.ui.DetailHostOpts
---@field stack gg.ui.Stack
---@field cfg gg.ui.Config
---@field name string e.g. "issue" (filetype "gg_ui_detail_issue")
---@field tabs? gg.ui.TabSpec[] nil: one unnamed content buffer
---@field sidebar? boolean wants a sidebar
---@field on_render? fun() redraw everything (resize, colourscheme, sidebar change)
---@field on_refresh? fun() `R`
---@field on_tab? fun(key: string) a tab became active

---@class gg.ui.DetailHost
---@field stack gg.ui.Stack
---@field cfg gg.ui.Config
---@field keys gg.ui.Keymaps
---@field group gg.ui.FloatGroup
---@field tabs gg.ui.TabSpec[]
---@field active string active tab key
---@field bufs table<string, integer> tab key -> buffer
---@field docs table<integer, gg.ui.Doc> buffer -> its last document
---@field ns integer
---@field closed boolean
local Host = {}
Host.__index = Host

local function map(buf, k, fn, desc)
  for _, lhs in ipairs(require("gg.ui.components.picker").lhs_list(k)) do
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
end

--- Open the windows (the content window takes the focus).
---@param opts gg.ui.DetailHostOpts
---@return gg.ui.DetailHost
function M.new(opts)
  local self = setmetatable({
    stack = opts.stack,
    cfg = opts.cfg,
    keys = opts.cfg.keymaps,
    name = opts.name,
    tabs = opts.tabs or { { key = "main", label = "" } },
    named_tabs = opts.tabs ~= nil,
    want_sidebar = opts.sidebar == true,
    bufs = {},
    docs = {},
    header_h = 1,
    closed = false,
    _on_render = opts.on_render,
    _on_refresh = opts.on_refresh,
    _on_tab = opts.on_tab,
    _maps = {}, -- keymaps for every tab buffer: { k, fn, desc }
    ns = vim.api.nvim_create_namespace("gg.ui.detail"),
    _title = " ",
    _footers = {},
  }, Host)
  self.active = self.tabs[1].key
  -- every border gray, focused or not
  self.group = float_group.new({
    layout = function()
      return self:_rects()
    end,
    border_hl = "GitlabDetailBorder",
    border_active_hl = "GitlabDetailBorder",
  })
  self.header_float = self.group:add({
    name = "header",
    focusable = false,
    filetype = "gg_ui_detail_header",
    win_opts = SIDE_WIN_OPTS,
  })
  self.content_float = self.group:add({
    name = "content",
    enter = true,
    buf = self:buf(self.active),
    title = " ",
    win_opts = CONTENT_WIN_OPTS,
    winhighlight = "CursorLine:GitlabCursorLine",
  })
  self:_sync_sidebar()
  self:_shared_maps()
  self.augroup = vim.api.nvim_create_augroup(("gg.ui.detail.%d"):format(self.content_float.win), { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = self.augroup,
    callback = function()
      vim.schedule(function()
        self:render()
      end)
    end,
  })
  self.group:on_resize(function()
    self:_sync_sidebar()
    self:render()
  end)
  self.group:on_close(function()
    self:_teardown()
  end)
  self:_chrome()
  ---@type gg.ui.Screen
  self.screen = { group = self.group }
  return self
end

---@private
function Host:_rects()
  local r = layout.detail({ header_h = self.header_h, sidebar = self.want_sidebar })
  return r
end

--- True while the sidebar is shown.
---@return boolean
function Host:has_sidebar()
  return self.group.members.sidebar ~= nil
end

-- add or remove the sidebar after a resize
---@private
function Host:_sync_sidebar()
  local want = self.want_sidebar and layout.has_sidebar()
  if want and not self:has_sidebar() then
    self.sidebar_float = self.group:add({
      name = "sidebar",
      focusable = false,
      filetype = "gg_ui_detail_sidebar",
      win_opts = SIDE_WIN_OPTS,
    })
    self.group:relayout()
  elseif not want and self:has_sidebar() then
    self.group:remove("sidebar")
    self.sidebar_float = nil
    self.group:relayout()
  end
end

--- The buffer of tab `key` (created on first use).
---@param key string
---@return integer
function Host:buf(key)
  local buf = self.bufs[key]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = float.scratch(("gg_ui_detail_%s"):format(self.name))
  -- tabs are swapped in and out of the content window: keep them loaded
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = false
  self.bufs[key] = buf
  for _, m in ipairs(self._maps) do
    map(buf, m[1], m[2], m[3])
  end
  return buf
end

--- Map `k` in every tab buffer (now and later ones).
---@param k gg.ui.Keymap
---@param fn fun()
---@param desc string
function Host:map_all(k, fn, desc)
  table.insert(self._maps, { k, fn, desc })
  for _, buf in pairs(self.bufs) do
    map(buf, k, fn, desc)
  end
end

--- Map `k` in the buffer of tab `key` only.
---@param key string
---@param k gg.ui.Keymap
---@param fn fun()
---@param desc string
function Host:map(key, k, fn, desc)
  map(self:buf(key), k, fn, desc)
end

---@private
function Host:_shared_maps()
  local k = self.keys
  self:map_all(k.close, function()
    self.stack:pop()
  end, "Back")
  self:map_all(k.close_all, function()
    self.stack:close()
  end, "Close")
  self:map_all(k.refresh, function()
    if self._on_refresh then
      self._on_refresh()
    end
  end, "Reload")
  if #self.tabs > 1 then
    self:map_all(k.detail_next_tab, function()
      self:cycle_tab(1)
    end, "Next tab")
    self:map_all(k.detail_prev_tab, function()
      self:cycle_tab(-1)
    end, "Previous tab")
  end
end

--- Map keymap `name` in tab `key` to a feature that comes later (the key
--- says so) and return its hint `[<key>] <desc>`.
---@param key string
---@param name string a keymap option, e.g. "edit"
---@param desc string
---@param what string e.g. "editing"
---@return gg.ui.Hint
function Host:map_later(key, name, desc, what)
  self:map(key, self.keys[name], function()
    vim.notify(("gg.ui: %s is not available yet"):format(what), vim.log.levels.INFO)
  end, desc)
  return { key = require("gg.ui.components.picker").first_key(self.keys[name]), desc = desc }
end

--- Map the edit key in tab `key` and return its hint. Editing is not part
--- of the detail views yet: the key says so.
---@param key string
---@return gg.ui.Hint
function Host:map_edit(key)
  return self:map_later(key, "edit", "Edit", "editing")
end

--- Show tab `key` in the content window.
---@param key string
function Host:show_tab(key)
  if self.closed then
    return
  end
  self.active = key
  local win = self.content_float.win
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_buf(win, self:buf(key))
    for o, v in pairs(CONTENT_WIN_OPTS) do
      vim.api.nvim_set_option_value(o, v, { win = win })
    end
  end
  self:_chrome()
  if self._on_tab then
    self._on_tab(key)
  end
end

--- Next (1) or previous (-1) tab, wrapping around.
---@param dir integer
function Host:cycle_tab(dir)
  local idx = 1
  for i, t in ipairs(self.tabs) do
    if t.key == self.active then
      idx = i
    end
  end
  self:show_tab(self.tabs[(idx - 1 + dir) % #self.tabs + 1].key)
end

--- Update the tab labels (counts) without switching.
---@param tabs gg.ui.TabSpec[]
function Host:set_tabs(tabs)
  self.tabs = tabs
  self:_chrome()
end

--- Set the footer hints of tab `key` (`[<key>] <description>`); `tail`
--- chunks follow them (e.g. a summary).
---@param key string
---@param hints gg.ui.Hint[]
---@param tail? gg.ui.Chunk[]
function Host:set_hints(key, hints, tail)
  local list = {}
  for _, h in ipairs(hints) do
    if h.key then
      table.insert(list, h)
    end
  end
  self._footers[key] = list
  self._tails = self._tails or {}
  self._tails[key] = tail
  if key == self.active then
    self:_chrome()
  end
end

---@private
function Host:_chrome()
  local win = self.content_float and self.content_float.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local title = self.named_tabs and header.tabs_title(self.tabs, self.active) or (self._title or " ")
  local hints = self._footers[self.active]
  local footer = hints and #hints > 0 and hint.chunks(hints) or nil
  local tail = self._tails and self._tails[self.active]
  if tail then
    footer = vim.list_extend(footer or {}, tail)
  end
  -- no hints: no footer at all (a placeholder would break the border)
  footer = footer or ""
  float.set_text(win, { title = title, footer = footer })
end

--- Set the content window's title (views without tabs).
---@param title string|gg.ui.Chunk[]
function Host:set_title(title)
  self._title = title
  self:_chrome()
end

--- Write `d` into `buf` (lines, highlights, whole-line backgrounds).
---@param buf integer
---@param d gg.ui.Doc
function Host:write(buf, d)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, d.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
  for _, h in ipairs(d.line_hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, self.ns, h.row, 0, { line_hl_group = h.hl, priority = 10 })
  end
  for _, m in ipairs(d.marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, self.ns, m.row, m.col, {
      end_col = m.end_col,
      hl_group = m.hl,
      priority = m.priority or 100,
      strict = false,
    })
  end
  self.docs[buf] = d
end

--- Write the content of tab `key` below an empty first line (space
--- between the border and the text); the cursor stays on its line
--- (clamped).
---@param key string
---@param d gg.ui.Doc
function Host:set_content(key, d)
  local padded = doc.new()
  padded:blank()
  padded:append(d)
  self:write(self:buf(key), padded)
end

--- Write the header body and its border texts; resizes the header to fit.
---@param d gg.ui.Doc
---@param title gg.ui.Chunk[] border title (see `header.border_title`)
---@param footer? gg.ui.Chunk[]|string border footer
function Host:set_header(d, title, footer)
  if self.closed then
    return
  end
  self:write(self.header_float.buf, d)
  local h = math.max(1, #d.lines)
  float.set_text(self.header_float.win, { title = title, footer = footer or "" })
  if h ~= self.header_h then
    self.header_h = h
    self.group:relayout()
  end
end

--- Write the sidebar (a no-op while it is hidden).
---@param d gg.ui.Doc
function Host:set_sidebar(d)
  if self.sidebar_float then
    -- the same empty first line as the tabs, so both start level
    local padded = doc.new()
    padded:blank()
    padded:append(d)
    self:write(self.sidebar_float.buf, padded)
  end
end

--- Inner width of the header window.
---@return integer
function Host:header_width()
  local win = self.header_float.win
  return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or layout.editor().columns - 2
end

--- Inner width of the content window.
---@return integer
function Host:content_width()
  local win = self.content_float.win
  return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or 80
end

--- Inner height of the content window.
---@return integer
function Host:content_height()
  local win = self.content_float.win
  return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_height(win) or 20
end

--- Inner width of the sidebar, or nil without one.
---@return integer|nil
function Host:sidebar_width()
  local f = self.sidebar_float
  return f and vim.api.nvim_win_is_valid(f.win) and vim.api.nvim_win_get_width(f.win) or nil
end

--- The metadata of the line under the cursor in the active tab (see
--- `gg.ui.Doc.rows`), and the line number.
---@return table|nil info
---@return integer|nil lnum
function Host:current()
  local win = self.content_float.win
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local d = self.docs[vim.api.nvim_win_get_buf(win)]
  return d and d.rows[lnum] or nil, lnum
end

--- Put the cursor on line `lnum` of the active tab (clamped).
---@param lnum integer
function Host:set_cursor(lnum)
  local win = self.content_float.win
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, math.min(count, lnum)), 0 })
end

--- True while the host's windows are open and on top.
---@return boolean
function Host:visible()
  return not self.closed and not self.group:is_hidden()
end

--- Redraw everything (the view's `on_render`).
function Host:render()
  if self.closed then
    return
  end
  self:_chrome()
  if self._on_render then
    self._on_render()
  end
end

--- Close this view (back to the screen below).
function Host:close()
  if not self.closed then
    self.stack:pop()
  end
end

---@private
function Host:_teardown()
  if self.closed then
    return
  end
  self.closed = true
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  for _, buf in pairs(self.bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

return M
