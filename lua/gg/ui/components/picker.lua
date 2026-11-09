--- The picker shell: a filter prompt above a table, shared by the views
--- (issues, merge requests, pipelines). `<Tab>` swaps the active view in the same
--- windows; every view keeps its own data, tab, filter text and selection.
---
--- The shell owns the windows, the prompt, the list buffer (cursor rules),
--- the hidden cursor, the cursor-mark / row-highlight overlay, the shared
--- keymaps and re-rendering on resize or a colourscheme change. A view
--- implements:
---   name, filetype, query, placeholder, rendered (rows[l].mark_col)
---   activate()          made active (first time: start loading)
---   render()            draw into the table (only while active)
---   load()              reload from the API (`R`)
---   set_query(s)        the filter text changed
---   switch_tab(dir)     next / previous state tab
---   on_select(lnum)     the cursor moved to `lnum` (or nil)
---   keymaps()           { { lhs, fn, desc } } for the table, while active
---   teardown()          the picker closed
local float = require("gg.ui.components.float")
local float_group = require("gg.ui.components.float_group")
local hint = require("gg.ui.lib.hint")
local layout = require("gg.ui.components.layout")
local list_buffer = require("gg.ui.components.list_buffer")
local prompt = require("gg.ui.components.prompt")

local M = {}

--- The views `<Tab>` cycles through, in order, and their modules.
M.VIEWS = { "issues", "merge_requests", "pipelines" }
M.MODULES = {
  issues = "gg.ui.issues.view",
  merge_requests = "gg.ui.merge_requests.view",
  pipelines = "gg.ui.pipelines.view",
}

M.CURSOR_MARK = "▌"

local TABLE_WIN_OPTS = {
  cursorline = false, -- the row highlight is an overlay
  wrap = false,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  spell = false,
  list = false,
}

---@class gg.ui.Picker
---@field cfg gg.ui.Config
---@field keys gg.ui.Keymaps
---@field host string|nil the resolved target, shared by the views
---@field project string|nil
---@field target_opts { arg?: string, cwd?: string }|nil how to resolve the target
---@field group gg.ui.FloatGroup
---@field filter_float gg.ui.Float
---@field table_float gg.ui.Float
---@field prompt gg.ui.Prompt
---@field list gg.ui.ListBuffer
---@field ns integer overlay namespace
---@field views table<string, table>
---@field active table|nil
---@field closed boolean
local Picker = {}
Picker.__index = Picker

local function stack()
  local r = layout.stack({ { height = 1 }, { fill = true } }, { gap = 0 })
  return { filter = r[1], table = r[2] }
end

--- Every lhs of a keymap option (a string, a list, or false).
---@param k gg.ui.Keymap|nil
---@return string[]
function M.lhs_list(k)
  if not k then
    return {}
  end
  if type(k) == "table" then
    return k
  end
  return { k }
end

--- The key shown in hints for a keymap option (its first lhs).
---@param k gg.ui.Keymap|nil
---@return string|nil
function M.first_key(k)
  return M.lhs_list(k)[1]
end

local function map(buf, modes, k, fn, desc)
  for _, lhs in ipairs(M.lhs_list(k)) do
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
end

--- Open the windows. No view is active yet; add one with `attach` +
--- `activate`.
---@param opts { cfg: gg.ui.Config, filetype?: string, host?: string, project?: string, target_opts?: table }
---@return gg.ui.Picker
function M.new(opts)
  local cfg = opts.cfg
  local self = setmetatable({
    cfg = cfg,
    keys = cfg.keymaps,
    host = opts.host,
    project = opts.project,
    target_opts = opts.target_opts,
    views = {},
    closed = false,
    _view_maps = {},
    ns = vim.api.nvim_create_namespace("gg.ui.picker.overlay"),
  }, Picker)

  self.group = float_group.new({ layout = stack })
  local fkey = M.first_key(self.keys.focus_filter)
  local filter_title = fkey and hint.chunks({ { key = fkey, desc = "Filter" } }, { desc_hl = "GitlabPickerTitle" }) or " Filter "
  self.filter_float = self.group:add({ name = "filter", title = filter_title, filetype = "gg_ui_filter", win_opts = { wrap = false } })
  self.table_float = self.group:add({
    name = "table",
    enter = true,
    title = " Table ",
    footer = " ",
    -- always gray: the cursor mark shows when the table has focus
    border_hl = "GitlabTableBorder",
    border_active_hl = "GitlabTableBorder",
    filetype = opts.filetype,
    win_opts = TABLE_WIN_OPTS,
  })

  self.prompt = prompt.new({
    buf = self.filter_float.buf,
    debounce_ms = cfg.filter_debounce_ms,
    on_change = function(s)
      if self.active then
        self.active:set_query(s)
      end
    end,
  })
  self.list = list_buffer.new({
    buf = self.table_float.buf,
    win = self.table_float.win,
    on_select = function(lnum)
      if self.active then
        self.active:on_select(lnum)
      end
    end,
    -- the cursor rests on the cursor-mark column
    cursor_col = function(lnum)
      local r = self.active and self.active.rendered
      local row = r and r.rows[lnum]
      return row and row.mark_col or 0
    end,
  })
  self.list:attach_navigation()
  self:_keymaps()

  local tbuf = self.table_float.buf
  self.augroup = vim.api.nvim_create_augroup(("gg.ui.picker.%d"):format(tbuf), { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = self.augroup,
    callback = function()
      vim.schedule(function()
        self:render()
      end)
    end,
  })
  -- the table draws its own cursor mark, so the real cursor is hidden there
  vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
    group = self.augroup,
    buffer = tbuf,
    callback = function(ev)
      self:_hide_cursor(ev.event == "WinEnter")
    end,
  })
  self.group:on_resize(function()
    self:render()
  end)
  self.group:on_close(function()
    self:_teardown()
  end)
  self.group:focus("table")
  self:_hide_cursor(vim.api.nvim_get_current_win() == self.table_float.win)
  return self
end

--- Register a view under its name (it does not become active).
---@param view table
function Picker:add(view)
  self.views[view.name] = view
end

--- True when `view` is the one drawn in the table.
---@param view table
---@return boolean
function Picker:is_active(view)
  return not self.closed and self.active == view
end

--- Make `view` the active one: its keymaps, filter text and placeholder,
--- then `view:activate()`.
---@param view table
function Picker:activate(view)
  if self.closed then
    return
  end
  local buf = self.table_float.buf
  for _, lhs in ipairs(self._view_maps) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
  self._view_maps = {}
  self.active = view
  self:add(view)
  for _, m in ipairs(view:keymaps()) do
    for _, lhs in ipairs(M.lhs_list(m[1])) do
      vim.keymap.set("n", lhs, m[2], { buffer = buf, nowait = true, silent = true, desc = m[3] })
      table.insert(self._view_maps, lhs)
    end
  end
  if view.filetype and vim.bo[buf].filetype ~= view.filetype then
    vim.bo[buf].filetype = view.filetype
  end
  self.prompt:set_placeholder(view.placeholder or "filter")
  -- the view's own filter text; on_change goes to the view just activated
  self.prompt:set_text(view.query or "")
  view:activate()
end

--- Switch to the next (1) or previous (-1) view, creating it on first use.
---@param dir integer
function Picker:cycle(dir)
  if self.closed or not self.active then
    return
  end
  local idx = 1
  for i, name in ipairs(M.VIEWS) do
    if name == self.active.name then
      idx = i
    end
  end
  local name = M.VIEWS[(idx - 1 + dir) % #M.VIEWS + 1]
  if name == self.active.name then
    return
  end
  local view = self.views[name] or require(M.MODULES[name]).attach(self)
  self:activate(view)
end

--- Redraw the active view.
function Picker:render()
  if self.active and not self.closed then
    self.active:render()
  end
end

--- Draw the cursor mark and the row highlight on line `lnum` (nil clears).
--- `extra(set)` may add view-specific overlays with `set(row0, col, opts)`.
---@param lnum integer|nil
---@param extra? fun(set: fun(row: integer, col: integer, o: table))
function Picker:overlay(lnum, extra)
  local buf = self.table_float.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
  local r = self.active and self.active.rendered
  local row = r and lnum and r.rows[lnum]
  if not row or not row.mark_col then
    return
  end
  local set = function(l, col, o)
    o.strict = false
    pcall(vim.api.nvim_buf_set_extmark, buf, self.ns, l, col, o)
  end
  set(lnum - 1, row.mark_col, { end_row = lnum, end_col = 0, hl_group = "GitlabCursorLine", hl_eol = true, priority = 100 })
  set(lnum - 1, row.mark_col, { virt_text = { { M.CURSOR_MARK, "GitlabCursorMark" } }, virt_text_pos = "overlay", priority = 200 })
  if extra then
    extra(set)
  end
end

--- Set the table's title and footer.
---@param title string|gg.ui.Chunk[]
---@param footer string|gg.ui.Chunk[]
function Picker:chrome(title, footer)
  float.set_text(self.table_float.win, { title = title, footer = footer })
end

--- The width of the table window.
---@return integer
function Picker:width()
  return vim.api.nvim_win_get_width(self.table_float.win)
end

--- True while the table window is open.
---@return boolean
function Picker:valid()
  return not self.closed and vim.api.nvim_win_is_valid(self.table_float.win)
end

-- Hide the cursor in Normal/Visual mode (guicursor with a blend = 100
-- group), or restore the user's 'guicursor'.
---@private
function Picker:_hide_cursor(hide)
  if hide and not self.saved_guicursor then
    self.saved_guicursor = vim.o.guicursor
    local base = self.saved_guicursor ~= "" and (self.saved_guicursor .. ",") or ""
    vim.o.guicursor = base .. "n-v-ve:GitlabHiddenCursor"
  elseif not hide and self.saved_guicursor then
    vim.o.guicursor = self.saved_guicursor
    self.saved_guicursor = nil
  end
end

--- Focus the filter in insert mode, at the end of the text.
function Picker:focus_filter()
  self.group:focus("filter")
  vim.cmd("startinsert!")
end

--- Back to the table (the filter stays).
function Picker:focus_table()
  vim.cmd("stopinsert")
  self.group:focus("table")
end

---@private
function Picker:_keymaps()
  local k = self.keys
  local tb, fb = self.table_float.buf, self.filter_float.buf
  local function on_active(method, ...)
    local args = { ... }
    return function()
      if self.active then
        self.active[method](self.active, unpack(args))
      end
    end
  end
  map(tb, "n", k.focus_filter, function()
    self:focus_filter()
  end, "Filter")
  map(tb, "n", k.next_tab, on_active("switch_tab", 1), "Next tab")
  map(tb, "n", k.prev_tab, on_active("switch_tab", -1), "Previous tab")
  map(tb, "n", k.refresh, on_active("load"), "Reload")
  map(tb, "n", k.close, function()
    self:close()
  end, "Close")
  map(tb, "n", k.next_view, function()
    self:cycle(1)
  end, "Next view")
  map(tb, "n", k.prev_view, function()
    self:cycle(-1)
  end, "Previous view")
  map(fb, { "i", "n" }, k.filter_submit, function()
    self:focus_table()
  end, "Back to the table")
  map(fb, { "i", "n" }, k.filter_clear, function()
    self.prompt:set_text("")
    self:focus_table()
  end, "Clear the filter")
end

--- Close the picker (both windows); every view cancels its requests.
function Picker:close()
  self.group:close()
end

---@private
function Picker:_teardown()
  if self.closed then
    return
  end
  self.closed = true
  self:_hide_cursor(false)
  for _, view in pairs(self.views) do
    pcall(view.teardown, view)
  end
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if self.prompt then
    self.prompt:destroy()
  end
end

return M
