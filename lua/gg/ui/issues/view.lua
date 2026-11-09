--- The issues picker: a filter prompt above a table of one project's issues,
--- grouped by milestone, with Open/Closed/All tabs and client-side pages.
---
--- Open and closed issues load in two parallel streams of pages
--- (`gg.issues.list`, see `gg.ui.components.streams`). The table is drawn
--- as soon as the first page arrives and grows while the rest loads; tabs
--- still loading show "…" after their count. Tab, filter and paging then
--- work locally without requests. `R` reloads and keeps the current rows
--- until each stream has finished.
---
--- The windows, prompt, cursor rules and shared keys are the picker shell
--- (`gg.ui.components.picker`); `<Tab>` switches to the merge requests view.
local gg = require("gg")
local config = require("gg.ui.config")
local date = require("gg.ui.lib.date")
local highlights = require("gg.ui.highlights")
local hint = require("gg.ui.lib.hint")
local model = require("gg.ui.issues.model")
local paginate = require("gg.ui.issues.paginate")
local picker = require("gg.ui.components.picker")
local project = require("gg.ui.project")
local render = require("gg.ui.issues.render")
local streams = require("gg.ui.components.streams")

local M = {}

---@class gg.ui.IssuesViewOpts
---@field arg? string `[host/]group/project` or a remote URL; default: the git remote
---@field host? string with `project`: open this target directly
---@field project? string
---@field cwd? string where to look for the git remote
---@field today? gg.ui.Date for tests; default: the local date
---@field config? gg.ui.Config for tests; default: the configured UI options

---@class gg.ui.IssuesView
---@field name "issues"
---@field shell gg.ui.Picker
---@field host string|nil
---@field project string|nil
---@field status "idle"|"loading"|"ready"|"error"
---@field tab gg.ui.Tab
---@field query string
---@field page integer
---@field pages gg.ui.Page[]
---@field issues gg.Issue[]|nil every loaded issue (both states)
---@field by_state { opened: gg.Issue[], closed: gg.Issue[] }|nil
---@field pending { opened: boolean, closed: boolean } streams still loading
---@field refreshing boolean old rows stay until each stream has finished
---@field truncated boolean
---@field touched boolean the user moved the selection (else it stays on the first row)
---@field selected_iid integer|nil
---@field rendered gg.ui.Rendered|nil
---@field group gg.ui.FloatGroup
---@field list gg.ui.ListBuffer
---@field prompt gg.ui.Prompt
---@field closed boolean
local View = {}
View.__index = View

local STATES = { "opened", "closed" }

--- Create the issues view inside an open picker (not activated).
---@param shell gg.ui.Picker
---@param opts? gg.ui.IssuesViewOpts
---@return gg.ui.IssuesView
function M.attach(shell, opts)
  opts = opts or {}
  local self = setmetatable({
    name = "issues",
    filetype = "gg_ui_issues",
    placeholder = "Filter",
    shell = shell,
    cfg = shell.cfg,
    keys = shell.keys,
    today = opts.today,
    status = "idle",
    tab = "opened",
    query = "",
    page = 1,
    pages = { { blocks = {}, count = 0 } },
    touched = false,
    closed = false,
    -- the shell's windows and parts, under the names the view always had
    group = shell.group,
    list = shell.list,
    prompt = shell.prompt,
    filter_float = shell.filter_float,
    table_float = shell.table_float,
    ns = shell.ns,
  }, View)
  streams.init(self, STATES)
  shell:add(self)
  return self
end

--- Open a picker on the issues view. Returns at once; issues load in the
--- background.
---@param opts? gg.ui.IssuesViewOpts
---@return gg.ui.IssuesView
function M.open(opts)
  opts = opts or {}
  local cfg = opts.config or config.get()
  highlights.setup()
  local direct = opts.host and opts.project
  local shell = picker.new({
    cfg = cfg,
    filetype = "gg_ui_issues",
    host = direct and opts.host or nil,
    project = direct and opts.project or nil,
    target_opts = not direct and { arg = opts.arg or opts.project, cwd = opts.cwd } or nil,
  })
  local self = M.attach(shell, opts)
  shell:activate(self)
  return self
end

--- Called by the picker when this view becomes active: the first time it
--- starts loading, later it redraws.
function View:activate()
  if self.status == "idle" then
    if self.shell.host then
      self.host, self.project = self.shell.host, self.shell.project
      self:load()
    else
      self:render()
      self:_resolve()
    end
    return
  end
  self:render()
end

---@private
function View:_resolve()
  self.status = "loading"
  self:render()
  local task = project.resolve(self.shell.target_opts or {})
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
    self.shell.host, self.shell.project = target.host, target.project
    self.host, self.project = target.host, target.project
    self:load()
  end)
end

--- (Re)load every issue of the project from the API: open and closed issues
--- in two parallel streams, up to `limit` each.
function View:load()
  if self.closed then
    return
  end
  if not self.host then
    return self:_resolve()
  end
  streams.start(self, {
    limit = self.cfg.limit,
    has_items = self.status == "ready" and self.issues ~= nil,
    fetch = function(state, cursor, per_page)
      return gg.issues.list({
        host = self.host,
        project = self.project,
        state = state,
        -- recently updated first: the first pages are the most relevant ones,
        -- and a limit cuts the stalest issues (the table sorts on its own)
        order_by = "updated_at",
        sort = "desc",
      }, { per_page = per_page, cursor = cursor })
    end,
    on_start = function()
      if not self.refreshing then
        self.status, self.issues = "loading", nil
      end
      self:render()
    end,
    on_update = function(all)
      self.issues, self.status = all, "ready"
      self:render()
    end,
    on_error = function(err)
      self.status, self.err_msg = "error", err.message or tostring(err)
      self:render()
    end,
  })
end

--- Redraw the table from the current state; the selection survives. A no-op
--- while another view is active.
function View:render()
  if self.closed or not self.shell:is_active(self) or not self.shell:valid() then
    return
  end
  if not self.touched then
    -- nothing chosen yet: stay on the first row while pages arrive
    self.selected_iid, self.sel_row = nil, nil
  end
  local mdl
  if self.issues and self.status ~= "error" then
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
  local pending = (self.status == "ready" and not self.refreshing) and self.pending or nil
  local r = render.render({
    width = self.shell:width(),
    status = self.status == "idle" and "loading" or self.status,
    pending = pending,
    tab = self.tab,
    model = mdl,
    page = self.pages[self.page],
    error = self.err_msg,
    loaded = self.loaded,
    truncated = self.truncated and self.cfg.limit or nil,
    retry_key = picker.first_key(self.keys.refresh) or false,
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
  self._rendering = true
  self.list:select(target or self.sel_row)
  self._rendering = false

  self.prompt:set_counter(mdl and mdl.filtered and ("%d / %d"):format(mdl.matching, mdl.total) or nil)
  self.shell:chrome(self:_title(), self:_footer())
end

---@private
function View:_title()
  if self.refreshing then
    return " Table · refreshing… "
  end
  if self.status == "ready" and (self.pending.opened or self.pending.closed) then
    return (" Table · loading… %d "):format(self.loaded)
  end
  return " Table "
end

---@private
function View:_footer()
  local hints = {}
  local k = picker.first_key
  -- like the Milestone column: only when some loaded issue has a milestone
  if k(self.keys.inspect_milestone) and self.model and self.model.has_milestones then
    table.insert(hints, { key = k(self.keys.inspect_milestone), desc = "Milestone" })
  end
  if k(self.keys.inspect_issue) then
    table.insert(hints, { key = k(self.keys.inspect_issue), desc = "Issue" })
  end
  local pages = self.pages and #self.pages or 1
  if pages > 1 and k(self.keys.next_page) then
    table.insert(hints, { key = k(self.keys.next_page), desc = ("Page %d/%d"):format(self.page, pages) })
  end
  if #hints == 0 then
    return " "
  end
  return hint.chunks(hints)
end

--- The cursor moved to `lnum` (called by the picker).
---@param lnum integer|nil
function View:on_select(lnum)
  local r = self.rendered
  local row = r and lnum and r.rows[lnum]
  if row and row.issue then
    self.selected_iid = row.issue.iid
    self.sel_row = lnum
    if not self._rendering then
      self.touched = true
    end
  end
  self:_overlay(row and row.issue and lnum or nil)
end

-- cursor mark and row highlight (the shell), plus the active milestone edge
---@private
function View:_overlay(lnum)
  local r = self.rendered
  local row = r and lnum and r.rows[lnum]
  self.shell:overlay(lnum, function(set)
    local block = r.blocks[row.block]
    if block and block.kind == "milestone" then
      for l = block.first, block.last do
        local edge = r.rows[l].edge
        if edge then
          set(l - 1, edge.col, { end_col = edge.end_col, hl_group = "GitlabMilestoneEdgeActive", priority = 5000 })
        end
      end
    end
  end)
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
  self.touched = true
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
  self.shell:focus_filter()
end

--- Back to the table (the filter stays).
function View:focus_table()
  self.shell:focus_table()
end

--- The view's own table keymaps (the shell maps the shared ones).
---@return { [1]: gg.ui.Keymap, [2]: fun(), [3]: string }[]
function View:keymaps()
  local k = self.keys
  return {
    { k.inspect_issue, function()
      self:inspect_issue()
    end, "Inspect issue" },
    { k.inspect_milestone, function()
      self:inspect_milestone()
    end, "Inspect milestone" },
    { k.next_page, function()
      self:next_page()
    end, "Next page" },
    { k.next_milestone, function()
      self:jump_milestone(1)
    end, "Next milestone" },
    { k.prev_milestone, function()
      self:jump_milestone(-1)
    end, "Previous milestone" },
  }
end

--- Close the picker (both windows) and cancel any request in flight.
function View:close()
  self.shell:close()
end

--- The picker closed: cancel everything (called by the picker).
function View:teardown()
  if self.closed then
    return
  end
  self.closed = true
  if self.task then
    self.task:cancel()
    self.task = nil
  end
  streams.cancel(self)
end

return M
