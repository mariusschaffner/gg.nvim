--- The issues picker: a filter prompt above a table of one project's issues,
--- grouped by milestone, with Open/Closed/All tabs and client-side pages.
---
--- All issues are fetched once (`gg.issues.list_all`, every state) and then
--- tab, filter and paging work locally without requests. `R` reloads.
local gg = require("gg")
local config = require("gg.ui.config")
local date = require("gg.ui.lib.date")
local float = require("gg.ui.components.float")
local float_group = require("gg.ui.components.float_group")
local highlights = require("gg.ui.highlights")
local hint = require("gg.ui.lib.hint")
local layout = require("gg.ui.components.layout")
local list_buffer = require("gg.ui.components.list_buffer")
local model = require("gg.ui.issues.model")
local paginate = require("gg.ui.issues.paginate")
local project = require("gg.ui.project")
local prompt = require("gg.ui.components.prompt")
local render = require("gg.ui.issues.render")

local M = {}

---@class gg.ui.IssuesViewOpts
---@field arg? string `[host/]group/project` or a remote URL; default: the git remote
---@field host? string with `project`: open this target directly
---@field project? string
---@field cwd? string where to look for the git remote
---@field today? gg.ui.Date for tests; default: the local date
---@field config? gg.ui.Config for tests; default: the configured UI options

---@class gg.ui.IssuesView
---@field host string|nil
---@field project string|nil
---@field status "loading"|"ready"|"error"
---@field tab gg.ui.Tab
---@field query string
---@field page integer
---@field pages gg.ui.Page[]
---@field issues gg.Issue[]|nil
---@field truncated boolean
---@field selected_iid integer|nil
---@field rendered gg.ui.Rendered|nil
---@field group gg.ui.FloatGroup
---@field list gg.ui.ListBuffer
---@field prompt gg.ui.Prompt
---@field closed boolean
local View = {}
View.__index = View

local TABLE_WIN_OPTS = {
  cursorline = false, -- the row highlight is an overlay on the issue part only
  wrap = false,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  spell = false,
  list = false,
}

local function stack()
  local r = layout.stack({ { height = 1 }, { fill = true } }, { gap = 0 })
  return { filter = r[1], table = r[2] }
end

local function map(buf, modes, lhs, fn, desc)
  if not lhs then
    return
  end
  vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
end

--- Open a picker. Returns at once; issues load in the background.
---@param opts? gg.ui.IssuesViewOpts
---@return gg.ui.IssuesView
function M.open(opts)
  opts = opts or {}
  local cfg = opts.config or config.get()
  highlights.setup()
  local self = setmetatable({
    cfg = cfg,
    keys = cfg.keymaps,
    today = opts.today,
    status = "loading",
    tab = "opened",
    query = "",
    page = 1,
    pages = { { blocks = {}, count = 0 } },
    truncated = false,
    loaded = 0,
    gen = 0,
    closed = false,
    ns = vim.api.nvim_create_namespace("gg.ui.issues.overlay"),
  }, View)

  self.group = float_group.new({ layout = stack })
  local filter_title = self.keys.focus_filter and hint.chunks({ { key = self.keys.focus_filter, desc = "Filter" } }, { desc_hl = "GitlabPickerTitle" }) or " Filter "
  local f = self.group:add({ name = "filter", title = filter_title, filetype = "gg_ui_filter", win_opts = { wrap = false } })
  local t = self.group:add({
    name = "table",
    enter = true,
    title = " Table ",
    footer = self:_footer(),
    filetype = "gg_ui_issues",
    win_opts = TABLE_WIN_OPTS,
  })
  self.filter_float, self.table_float = f, t

  self.prompt = prompt.new({
    buf = f.buf,
    debounce_ms = cfg.filter_debounce_ms,
    on_change = function(s)
      self:set_query(s)
    end,
  })
  self.list = list_buffer.new({
    buf = t.buf,
    win = t.win,
    on_select = function(lnum)
      self:_on_select(lnum)
    end,
    -- the cursor rests on the cursor-mark column, not on the milestone edge
    cursor_col = function(lnum)
      local row = self.rendered and self.rendered.rows[lnum]
      return row and row.mark_col or 0
    end,
  })
  self.list:attach_navigation()
  self:_keymaps()

  self.augroup = vim.api.nvim_create_augroup(("gg.ui.issues.%d"):format(t.buf), { clear = true })
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
    buffer = t.buf,
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
  self:_hide_cursor(vim.api.nvim_get_current_win() == t.win)

  if opts.host and opts.project then
    self.host, self.project = opts.host, opts.project
    self:load()
  else
    self.target_opts = { arg = opts.arg or opts.project, cwd = opts.cwd }
    self:render()
    self:_resolve()
  end
  return self
end

---@private
function View:_resolve()
  self.status = "loading"
  self:render()
  local task = project.resolve(self.target_opts)
  self.task = task
  task:on_done(function(target, err)
    if self.closed or self.task ~= task then
      return
    end
    self.task = nil
    if err then
      self.status, self.err_msg = "error", err.message or tostring(err)
      self:render()
      return
    end
    self.host, self.project = target.host, target.project
    self:load()
  end)
end

--- (Re)load every issue of the project from the API.
function View:load()
  if self.closed then
    return
  end
  if not self.host then
    return self:_resolve()
  end
  if self.task then
    self.task:cancel()
  end
  self.gen = self.gen + 1
  local gen = self.gen
  self.status, self.err_msg, self.loaded = "loading", nil, 0
  self:render()
  local task = gg.issues.list_all({
    host = self.host,
    project = self.project,
    state = "all",
    order_by = "milestone_due",
    sort = "asc",
  }, {
    limit = self.cfg.limit,
    per_page = math.min(100, self.cfg.limit),
    on_page = function(items)
      if self.closed or gen ~= self.gen then
        return
      end
      self.loaded = self.loaded + #items
      if not self.issues then
        self:render()
      end
    end,
  })
  self.task = task
  task:on_done(function(res, err)
    if self.closed or gen ~= self.gen then
      return
    end
    self.task = nil
    if err then
      self.status, self.err_msg = "error", err.message or tostring(err)
    else
      self.status, self.issues, self.truncated = "ready", res.items, res.truncated == true
    end
    self:render()
  end)
end

--- Redraw the table from the current state; the selection survives.
function View:render()
  if self.closed or not vim.api.nvim_win_is_valid(self.table_float.win) then
    return
  end
  local mdl
  if self.issues then
    mdl = model.build(self.issues, {
      tab = self.tab,
      query = self.query,
      today = self.today or date.today(),
      order = self.cfg.order,
    })
    self.pages = paginate.paginate(mdl.blocks, self.cfg.page_size)
    self.page = paginate.page_of(self.pages, self.selected_iid) or self.page
    self.page = math.max(1, math.min(#self.pages, self.page))
  end
  self.model = mdl
  local status = self.status
  if status == "loading" and self.issues then
    status = "ready" -- refreshing: keep the rows, the title says so
  end
  local r = render.render({
    width = vim.api.nvim_win_get_width(self.table_float.win),
    status = status,
    tab = self.tab,
    model = mdl,
    page = self.pages[self.page],
    error = self.err_msg,
    loaded = self.loaded,
    truncated = self.truncated and self.cfg.limit or nil,
    retry_key = self.keys.refresh,
    label_hl = highlights.label,
  })
  self.rendered = r
  self.list:set(r)

  -- keep the selected issue, else the nearest line
  local target
  if self.selected_iid then
    for _, lnum in ipairs(r.selectable) do
      local row = r.rows[lnum]
      if row.issue and row.issue.iid == self.selected_iid then
        target = lnum
        break
      end
    end
  end
  self.list:select(target or self.sel_row)

  self.prompt:set_counter(mdl and mdl.filtered and ("%d / %d"):format(mdl.matching, mdl.total) or nil)
  float.set_text(self.table_float.win, {
    title = (self.status == "loading" and self.issues) and " Table · refreshing… " or " Table ",
    footer = self:_footer(),
  })
end

---@private
function View:_footer()
  local hints = {}
  if self.keys.inspect_milestone then
    table.insert(hints, { key = self.keys.inspect_milestone, desc = "Milestone" })
  end
  if self.keys.inspect_issue then
    table.insert(hints, { key = self.keys.inspect_issue, desc = "Issue" })
  end
  local pages = self.pages and #self.pages or 1
  if pages > 1 and self.keys.next_page then
    table.insert(hints, { key = self.keys.next_page, desc = ("Page %d/%d"):format(self.page, pages) })
  end
  if #hints == 0 then
    return " "
  end
  return hint.chunks(hints)
end

-- Hide the cursor in Normal/Visual mode (guicursor with a blend = 100
-- group), or restore the user's 'guicursor'.
---@private
function View:_hide_cursor(hide)
  if hide and not self.saved_guicursor then
    self.saved_guicursor = vim.o.guicursor
    local base = self.saved_guicursor ~= "" and (self.saved_guicursor .. ",") or ""
    vim.o.guicursor = base .. "n-v-ve:GitlabHiddenCursor"
  elseif not hide and self.saved_guicursor then
    vim.o.guicursor = self.saved_guicursor
    self.saved_guicursor = nil
  end
end

---@private
function View:_on_select(lnum)
  local r = self.rendered
  local row = r and lnum and r.rows[lnum]
  if row and row.issue then
    self.selected_iid = row.issue.iid
    self.sel_row = lnum
  end
  self:_overlay(row and row.issue and lnum or nil)
end

-- cursor mark, row highlight and active milestone edge (second namespace)
---@private
function View:_overlay(lnum)
  local buf = self.table_float.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
  local r = self.rendered
  local row = r and lnum and r.rows[lnum]
  if not row or not row.mark_col then
    return
  end
  local set = function(l, col, o)
    o.strict = false
    pcall(vim.api.nvim_buf_set_extmark, buf, self.ns, l, col, o)
  end
  set(lnum - 1, row.mark_col, { end_row = lnum, end_col = 0, hl_group = "GitlabCursorLine", hl_eol = true, priority = 100 })
  set(lnum - 1, row.mark_col, { virt_text = { { render.CURSOR_MARK, "GitlabCursorMark" } }, virt_text_pos = "overlay", priority = 200 })
  local block = r.blocks[row.block]
  if block and block.kind == "milestone" then
    for l = block.first, block.last do
      local edge = r.rows[l].edge
      if edge then
        set(l - 1, edge.col, { end_col = edge.end_col, hl_group = "GitlabMilestoneEdgeActive", priority = 5000 })
      end
    end
  end
end

---@private
function View:_current_row()
  local lnum = self.list:current()
  return lnum and self.rendered and self.rendered.rows[lnum] or nil, lnum
end

--- Set the filter query and redraw.
---@param s string
function View:set_query(s)
  if self.closed or s == self.query then
    return
  end
  self.query = s
  self:render()
end

--- Switch to the next (1) or previous (-1) tab: Open -> Closed -> All.
---@param dir integer
function View:switch_tab(dir)
  local idx = 1
  for i, t in ipairs(model.TABS) do
    if t == self.tab then
      idx = i
    end
  end
  self.tab = model.TABS[(idx - 1 + dir) % #model.TABS + 1]
  self:render()
end

--- Next page, wrapping to the first.
function View:next_page()
  if #self.pages <= 1 then
    return
  end
  self.page = self.page % #self.pages + 1
  self.selected_iid, self.sel_row = nil, nil
  self:render()
end

--- Jump to the next (1) or previous (-1) milestone block on this page.
---@param dir integer
function View:jump_milestone(dir)
  local r = self.rendered
  local row = self:_current_row()
  if not r then
    return
  end
  local from = row and row.block or (dir > 0 and 0 or #r.blocks + 1)
  local i = from + dir
  while r.blocks[i] do
    if r.blocks[i].kind == "milestone" then
      self.list:select(r.blocks[i].first)
      return
    end
    i = i + dir
  end
end

---@private
function View:_ctx()
  return {
    host = self.host,
    project = self.project,
    close = function()
      self:close()
    end,
  }
end

local function call(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    vim.notify("gg.ui: " .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Call `on_inspect_issue` for the issue under the cursor.
function View:inspect_issue()
  local row = self:_current_row()
  if row and row.issue then
    call(self.cfg.on_inspect_issue, row.issue, self:_ctx())
  end
end

--- Call `on_inspect_milestone` for the milestone of the issue under the cursor.
function View:inspect_milestone()
  local row = self:_current_row()
  if not (row and row.issue) then
    return
  end
  if not row.issue.milestone then
    vim.notify("No milestone", vim.log.levels.INFO)
    return
  end
  call(self.cfg.on_inspect_milestone, row.issue.milestone, self:_ctx())
end

--- Focus the filter in insert mode, at the end of the text.
function View:focus_filter()
  self.group:focus("filter")
  vim.cmd("startinsert!")
end

--- Back to the table (the filter stays).
function View:focus_table()
  vim.cmd("stopinsert")
  self.group:focus("table")
end

---@private
function View:_keymaps()
  local k = self.keys
  local tb, fb = self.table_float.buf, self.filter_float.buf
  map(tb, "n", k.focus_filter, function()
    self:focus_filter()
  end, "Filter issues")
  map(tb, "n", k.inspect_issue, function()
    self:inspect_issue()
  end, "Inspect issue")
  map(tb, "n", k.inspect_milestone, function()
    self:inspect_milestone()
  end, "Inspect milestone")
  map(tb, "n", k.next_tab, function()
    self:switch_tab(1)
  end, "Next tab")
  map(tb, "n", k.prev_tab, function()
    self:switch_tab(-1)
  end, "Previous tab")
  map(tb, "n", k.next_page, function()
    self:next_page()
  end, "Next page")
  map(tb, "n", k.next_milestone, function()
    self:jump_milestone(1)
  end, "Next milestone")
  map(tb, "n", k.prev_milestone, function()
    self:jump_milestone(-1)
  end, "Previous milestone")
  map(tb, "n", k.refresh, function()
    self:load()
  end, "Reload issues")
  map(tb, "n", k.close, function()
    self:close()
  end, "Close")
  map(fb, { "i", "n" }, k.filter_submit, function()
    self:focus_table()
  end, "Back to the table")
  map(fb, { "i", "n" }, k.filter_clear, function()
    self.prompt:set_text("")
    self:focus_table()
  end, "Clear the filter")
end

--- Close the picker (both windows) and cancel any request in flight.
function View:close()
  self.group:close()
end

---@private
function View:_teardown()
  if self.closed then
    return
  end
  self.closed = true
  self:_hide_cursor(false)
  if self.task then
    self.task:cancel()
    self.task = nil
  end
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if self.prompt then
    self.prompt:destroy()
  end
end

return M
