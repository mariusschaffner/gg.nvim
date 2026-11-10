--- The pipelines view of the picker: one line per pipeline of the project,
--- newest first, with All/Running/Failed/Passed tabs.
---
--- Loading:
---   * One page of `PER_PAGE` pipelines (`gg.pipelines.list`); the rows show
---     at once with status, ref, SHA, commit title, source, stages and start
---     time (GraphQL returns them all in that one request). `P` loads the
---     next page and appends it; the rows already shown do not move.
---   * Two fills run once per load, in parallel: the project
---     (`gg.projects.get`: default branch -> ref colour, project id) and its
---     open merge requests (`gg.merge_requests.list_all`: the MR column of
---     branch pipelines). MR pipelines carry their merge request already.
---   * Every update rewrites only the lines whose text or highlights changed
---     (`_patch`), so the cursor never moves; when the rows themselves change
---     (a pipeline left the active tab) the table is redrawn and the
---     selection follows its pipeline.
---
--- Live updates, while this view is the active one:
---   * every `pipeline_refresh_ms` the active pipelines among the shown rows
---     are fetched again (`gg.pipelines.list` with `ids`, at most 20 per
---     request, `CONCURRENCY` requests at a time); the timer stops when no
---     shown pipeline is active, the view is inactive, or the picker closes.
---   * every `STARTED_MS` the relative "Started" times are redrawn.
---
--- The same table also lives inside the merge request detail view, filtered
--- to that merge request (`M.mount` with `mr_iid`). Everything that touches
--- the windows goes through a surface (`gg.ui.PipelinesSurface`): the
--- picker's (`M.attach`) or the detail view's.
local columns = require("gg.ui.pipelines.columns")
local date = require("gg.ui.lib.date")
local gg = require("gg")
local highlights = require("gg.ui.highlights")
local hint = require("gg.ui.lib.hint")
local model = require("gg.ui.pipelines.model")
local picker = require("gg.ui.components.picker")
local project = require("gg.ui.project")
local queue = require("gg.ui.components.queue")
local render = require("gg.ui.pipelines.render")

local M = {}

M.PER_PAGE = 50
M.CONCURRENCY = 4
M.STARTED_MS = 30000
M.MAX_IDS = 20

---@class gg.ui.PipelinesView
---@field name "pipelines"
---@field shell gg.ui.Picker
---@field host string|nil
---@field project string|nil
---@field status "idle"|"loading"|"ready"|"error"
---@field tab gg.ui.PipelineTab
---@field query string
---@field pipelines gg.Pipeline[] every loaded pipeline, in load order
---@field by_id table<integer, integer> pipeline id -> index in `pipelines`
---@field next_cursor string|nil
---@field ctx gg.ui.PipelineCtx
---@field model gg.ui.PipelineModel|nil
---@field rendered gg.ui.Rendered|nil
---@field selected_id integer|nil
---@field touched boolean
---@field queue gg.ui.Queue
---@field closed boolean
---@field surface gg.ui.PipelinesSurface
---@field mr_iid integer|nil only this merge request's pipelines
local View = {}
View.__index = View

---@class gg.ui.PipelinesSurface
---@field list gg.ui.ListBuffer the table buffer
---@field active fun(): boolean the table is visible (else render is a no-op and the timers stop)
---@field width fun(): integer
---@field chrome fun(title: string, footer: string|gg.ui.Chunk[])
---@field overlay fun(lnum: integer|nil) cursor mark and row highlight
---@field counter? fun(s: string|nil) the filter's match counter
---@field open fun(pipeline: gg.Pipeline) inspect
---@field close fun()

local function new(fields)
  return setmetatable(vim.tbl_extend("force", {
    name = "pipelines",
    status = "idle",
    tab = "all",
    query = "",
    pipelines = {},
    by_id = {},
    ctx = {},
    gen = 0,
    tasks = {},
    touched = false,
    closed = false,
    refreshing = false,
    loading_more = false,
    utc_offset = date.utc_offset(),
    queue = queue.new({ concurrency = M.CONCURRENCY }),
  }, fields), View)
end

--- Create the pipelines view inside an open picker (not activated).
---@param shell gg.ui.Picker
---@return gg.ui.PipelinesView
function M.attach(shell)
  local self = new({
    filetype = "gg_ui_pipelines",
    placeholder = "Filter",
    shell = shell,
    cfg = shell.cfg,
    keys = shell.keys,
    list = shell.list,
  })
  self.surface = {
    list = shell.list,
    active = function()
      return shell:is_active(self) and shell:valid()
    end,
    width = function()
      return shell:width()
    end,
    chrome = function(title, footer)
      shell:chrome(title, footer)
    end,
    overlay = function(lnum)
      shell:overlay(lnum)
    end,
    counter = function(c)
      shell.prompt:set_counter(c)
    end,
    open = function(p)
      require("gg.ui.detail").pipeline(shell:detail_ctx(self), p)
    end,
    close = function()
      shell:close()
    end,
  }
  shell:add(self)
  return self
end

--- The table outside the picker (the merge request detail view): one
--- project's pipelines, or only those of merge request `mr_iid`. Call
--- `activate` to load it.
---@param opts { surface: gg.ui.PipelinesSurface, cfg: gg.ui.Config, host: string, project: string, mr_iid?: integer }
---@return gg.ui.PipelinesView
function M.mount(opts)
  return new({
    surface = opts.surface,
    list = opts.surface.list,
    cfg = opts.cfg,
    keys = opts.cfg.keymaps,
    host = opts.host,
    project = opts.project,
    mr_iid = opts.mr_iid,
    -- merge request pipelines cannot be fetched by ids: one request each
    no_ids = opts.mr_iid ~= nil or nil,
  })
end

--- Called by the picker when this view becomes active: the first time it
--- starts loading, later it redraws (and resumes the timers).
function View:activate()
  highlights.setup()
  if self.status == "idle" then
    if self.host then
      self:load()
    elseif self.shell.host then
      self.host, self.project = self.shell.host, self.shell.project
      self:load()
    else
      self:_resolve()
    end
    return
  end
  self:render()
  self:_start_timers()
end

---@private
function View:_resolve()
  self.status = "loading"
  self:render()
  local t = project.resolve(self.shell.target_opts or {})
  self.tasks.resolve = t
  t:on_done(function(target, err)
    if self.closed or self.tasks.resolve ~= t then
      return
    end
    self.tasks.resolve = nil
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

---@private
function View:_cancel_tasks()
  for k, t in pairs(self.tasks) do
    t:cancel()
    self.tasks[k] = nil
  end
  self.queue:cancel_all()
  self.loading_more = false
end

---@private
function View:_set_pipelines(items)
  self.pipelines, self.by_id = {}, {}
  self:_append(items)
end

---@private
function View:_append(items)
  for _, p in ipairs(items or {}) do
    if p.id and not self.by_id[p.id] then
      table.insert(self.pipelines, p)
      self.by_id[p.id] = #self.pipelines
    end
  end
end

--- (Re)load the first page, the project and the open merge requests. On a
--- reload the current rows stay until the new page has arrived.
function View:load()
  if self.closed then
    return
  end
  if not self.host then
    return self:_resolve()
  end
  self:_cancel_tasks()
  self:_stop_refresh()
  self.gen = self.gen + 1
  local gen = self.gen
  self.refreshing = self.status == "ready" and #self.pipelines > 0
  if not self.refreshing then
    self.status, self.err_msg = "loading", nil
    self:_set_pipelines({})
    self.next_cursor = nil
  end
  self:render()
  local t = gg.pipelines.list(self:_list_args(), { per_page = M.PER_PAGE })
  self.tasks.page = t
  t:on_done(function(page, err)
    if self.closed or gen ~= self.gen then
      return
    end
    self.tasks.page = nil
    self.refreshing = false
    if err then
      self.status, self.err_msg = "error", err.message or tostring(err)
      self:render()
      return
    end
    self:_set_pipelines(page.items)
    self.next_cursor = page.next_cursor
    self.status = "ready"
    self:render()
    self:_start_timers()
  end)
  self:_load_context(gen)
end

---@private
function View:_list_args()
  return { host = self.host, project = self.project, mr_iid = self.mr_iid }
end

-- the default branch, the project id and the open merge requests
---@private
function View:_load_context(gen)
  local pt = gg.projects.get({ host = self.host, project = self.project })
  self.tasks.project = pt
  pt:on_done(function(p, err)
    if self.closed or gen ~= self.gen then
      return
    end
    self.tasks.project = nil
    if not err and p then
      self.ctx.default_branch = p.default_branch
      self.project_id = p.id
      self:_update_mr_map()
      self:_patch()
    end
  end)
  if self.mr_iid then
    -- every row belongs to this merge request: no branch lookup needed
    self.ctx.mr_by_branch = {}
    return
  end
  local mt = gg.merge_requests.list_all({ host = self.host, project = self.project, state = "opened" }, { limit = self.cfg.limit })
  self.tasks.mrs = mt
  mt:on_done(function(res, err)
    if self.closed or gen ~= self.gen then
      return
    end
    self.tasks.mrs = nil
    if err then
      self.open_mrs = nil
      self.ctx.mr_by_branch, self.ctx.mr_failed = nil, true
    else
      self.open_mrs = res.items or {}
      self.ctx.mr_failed = nil
      self:_update_mr_map()
    end
    self:_patch()
  end)
end

---@private
function View:_update_mr_map()
  if self.open_mrs then
    self.ctx.mr_by_branch = model.mr_map(self.open_mrs, self.project_id)
  end
end

---@private
function View:_output()
  local mdl
  if self.status == "ready" then
    mdl = model.build(self.pipelines, { tab = self.tab, query = self.query, ctx = self.ctx })
  end
  self.model = mdl
  return render.render({
    width = self.surface.width(),
    status = self.status == "idle" and "loading" or self.status,
    tab = self.tab,
    model = mdl,
    id_width = columns.id_width(self.pipelines),
    ctx = self.ctx,
    now = os.time(),
    utc_offset = self.utc_offset,
    error = self.err_msg,
    loaded = #self.pipelines,
    retry_key = picker.first_key(self.keys.refresh) or false,
  })
end

--- Redraw the table from the current state; the selection survives. A no-op
--- while another view is active.
function View:render()
  if self.closed or not self.surface.active() then
    return
  end
  if not self.touched then
    self.selected_id, self.sel_row = nil, nil
  end
  local r = self:_output()
  self.rendered = r
  self.list:set(r)
  local target
  if self.selected_id then
    for _, lnum in ipairs(r.selectable) do
      if r.rows[lnum].pipeline.id == self.selected_id then
        target = lnum
        break
      end
    end
  end
  self._rendering = true
  self.list:select(target or self.sel_row)
  self._rendering = false
  if self.surface.counter then
    self.surface.counter(nil) -- this view has no match counter
  end
  self.surface.chrome(self:_title(), self:_footer())
end

-- per row: its marks as one comparable string
local function mark_keys(r)
  local out = {}
  for _, m in ipairs(r.marks) do
    out[m.row] = (out[m.row] or "") .. ("%d:%d:%s;"):format(m.col, m.end_col, m.hl)
  end
  return out
end

--- Lines that differ between two renders of the same rows (text or
--- highlights), as 1-based line numbers.
---@param old gg.ui.Rendered
---@param new gg.ui.Rendered
---@return integer[]|nil nil when the rows differ (a full redraw is needed)
function M.changed_lines(old, new)
  if #old.lines ~= #new.lines or #old.selectable ~= #new.selectable then
    return nil
  end
  for i, lnum in ipairs(new.selectable) do
    if old.selectable[i] ~= lnum then
      return nil
    end
    local a, b = old.rows[lnum], new.rows[lnum]
    if not (a and b and a.pipeline and b.pipeline and a.pipeline.id == b.pipeline.id) then
      return nil
    end
  end
  local om, nm = mark_keys(old), mark_keys(new)
  local out = {}
  for lnum = 1, #new.lines do
    if old.lines[lnum] ~= new.lines[lnum] or om[lnum - 1] ~= nm[lnum - 1] then
      table.insert(out, lnum)
    end
  end
  return out
end

-- Rewrite only the lines that changed; redraw when the rows changed.
---@private
function View:_patch()
  if self.closed or not self.surface.active() or not self.rendered then
    return
  end
  local r = self:_output()
  local lnums = M.changed_lines(self.rendered, r)
  if not lnums then
    return self:render()
  end
  self.rendered = r
  if #lnums > 0 then
    self.list:patch(r, lnums)
    self.surface.overlay(self.list:current())
  end
  self.surface.chrome(self:_title(), self:_footer())
end

---@private
function View:_title()
  if self.refreshing then
    return " Table · refreshing… "
  end
  if self.loading_more then
    return (" Table · loading… %d "):format(#self.pipelines)
  end
  return " Table "
end

---@private
function View:_footer()
  local hints = {}
  local k = picker.first_key
  if k(self.keys.inspect_pipeline) then
    table.insert(hints, { key = k(self.keys.inspect_pipeline), desc = "Pipeline" })
  end
  if #hints == 0 then
    return " "
  end
  return hint.chunks(hints)
end

-- Timers ---------------------------------------------------------------------

local function stop_timer(t)
  if t and not t:is_closing() then
    t:stop()
    t:close()
  end
end

-- the active pipelines among the shown rows
---@private
function View:_active_ids()
  local ids = {}
  local r = self.rendered
  for _, lnum in ipairs(r and r.selectable or {}) do
    local p = r.rows[lnum].pipeline
    if p and model.is_active(p) then
      table.insert(ids, p.id)
    end
  end
  return ids
end

---@private
function View:_stop_refresh()
  stop_timer(self.refresh_timer)
  self.refresh_timer = nil
end

---@private
function View:_stop_timers()
  self:_stop_refresh()
  stop_timer(self.started_timer)
  self.started_timer = nil
end

--- Start the timers that apply now: the Started clock while active and
--- ready, the refresh while a shown pipeline is active (and it is on).
---@private
function View:_start_timers()
  if self.closed or self.suspended or self.status ~= "ready" or not self.surface.active() then
    return
  end
  if not self.started_timer then
    self.started_timer = vim.uv.new_timer()
    self.started_timer:start(M.STARTED_MS, M.STARTED_MS, vim.schedule_wrap(function()
      if self.closed or not self.surface.active() then
        return self:_stop_timers()
      end
      self:_patch()
    end))
  end
  local ms = self.cfg.pipeline_refresh_ms or 0
  if ms > 0 and not self.refresh_timer and #self:_active_ids() > 0 then
    self.refresh_timer = vim.uv.new_timer()
    self.refresh_timer:start(ms, ms, vim.schedule_wrap(function()
      self:_tick()
    end))
  end
end

--- One refresh: fetch the shown active pipelines again.
---@private
function View:_tick()
  if self.closed or not self.surface.active() then
    return self:_stop_timers()
  end
  if self.status ~= "ready" then
    return
  end
  local ids = self:_active_ids()
  if #ids == 0 then
    return self:_stop_refresh()
  end
  if self.no_ids then
    for _, id in ipairs(ids) do
      self.queue:push("refresh:" .. id, function()
        return gg.pipelines.get({ host = self.host, project = self.project, id = id })
      end, function(p, err)
        self:_refreshed(not err and p and { p } or nil)
      end)
    end
    return
  end
  for i = 1, #ids, M.MAX_IDS do
    local batch = vim.list_slice(ids, i, i + M.MAX_IDS - 1)
    self.queue:push("refresh:" .. table.concat(batch, ","), function()
      return gg.pipelines.list({ host = self.host, project = self.project, ids = batch }, { per_page = #batch })
    end, function(page, err)
      if err and (err.kind == "graphql" or err.kind == "validation") then
        self.no_ids = true -- this GitLab cannot filter by ids: one request each
      end
      self:_refreshed(not err and page and page.items or nil)
    end)
  end
end

-- Fresh copies of loaded pipelines arrived.
---@private
function View:_refreshed(items)
  if self.closed or not items then
    return
  end
  for _, p in ipairs(items) do
    local i = p.id and self.by_id[p.id]
    if i then
      self.pipelines[i] = p
    end
  end
  self:_patch()
  if #self:_active_ids() == 0 then
    self:_stop_refresh()
  end
end

--- A detail view covers the picker: stop the timers.
function View:suspend()
  self.suspended = true
  self:_stop_timers()
end

--- Visible again: refresh what is active now, then restart the timers.
function View:resume()
  self.suspended = false
  if self.closed or not self.surface.active() then
    return
  end
  self:_tick()
  self:_start_timers()
end

-- Interaction ----------------------------------------------------------------

--- The cursor moved to `lnum` (called by the picker).
---@param lnum integer|nil
function View:on_select(lnum)
  local r = self.rendered
  local row = r and lnum and r.rows[lnum]
  if row and row.pipeline then
    self.selected_id = row.pipeline.id
    self.sel_row = lnum
    if not self._rendering then
      self.touched = true
    end
  end
  self.surface.overlay(row and row.pipeline and lnum or nil)
end

--- Set the filter query and redraw.
---@param s string
function View:set_query(s)
  if self.closed or s == self.query then
    return
  end
  self.query = s
  self:render()
  self:_start_timers()
end

--- Switch to the next (1) or previous (-1) tab: All -> Running -> Failed -> Passed.
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
  self:_start_timers()
end

--- Load the next page of pipelines and append it. The rows shown stay
--- where they are (newer pipelines come first, the new page goes below).
function View:next_page()
  if self.closed or self.status ~= "ready" or not self.next_cursor or self.loading_more then
    return
  end
  self.loading_more = true
  self.surface.chrome(self:_title(), self:_footer())
  local gen = self.gen
  local t = gg.pipelines.list(self:_list_args(), { per_page = M.PER_PAGE, cursor = self.next_cursor })
  self.tasks.more = t
  t:on_done(function(page, err)
    if self.closed or gen ~= self.gen then
      return
    end
    self.tasks.more = nil
    self.loading_more = false
    if err then
      vim.notify("gg.ui: loading more pipelines failed: " .. (err.message or tostring(err)), vim.log.levels.WARN)
      self.surface.chrome(self:_title(), self:_footer())
      return
    end
    self:_append(page.items)
    self.next_cursor = page.next_cursor
    self:render()
    self:_start_timers()
  end)
end

--- Open the detail view of the pipeline under the cursor.
function View:inspect()
  local lnum = self.list:current()
  local row = lnum and self.rendered and self.rendered.rows[lnum]
  if row and row.pipeline then
    self.surface.open(row.pipeline)
  end
end

--- The view's own table keymaps (the shell maps the shared ones).
---@return { [1]: gg.ui.Keymap, [2]: fun(), [3]: string }[]
function View:keymaps()
  local k = self.keys
  return {
    { k.inspect_pipeline, function()
      self:inspect()
    end, "Inspect pipeline" },
    { k.next_page, function()
      self:next_page()
    end, "Load more pipelines" },
  }
end

--- Close the picker (both windows) and cancel any request in flight.
function View:close()
  self.surface.close()
end

--- The picker closed: stop the timers and cancel everything (called by the picker).
function View:teardown()
  if self.closed then
    return
  end
  self.closed = true
  self:_stop_timers()
  self:_cancel_tasks()
end

--- Open a picker on the pipelines view (same options as the issues view's
--- `open`).
---@param opts? { arg?: string, host?: string, project?: string, cwd?: string, config?: gg.ui.Config }
---@return gg.ui.PipelinesView
function M.open(opts)
  opts = opts or {}
  local cfg = opts.config or require("gg.ui.config").get()
  highlights.setup()
  local direct = opts.host and opts.project
  local shell = picker.new({
    cfg = cfg,
    filetype = "gg_ui_pipelines",
    host = direct and opts.host or nil,
    project = direct and opts.project or nil,
    target_opts = not direct and { arg = opts.arg or opts.project, cwd = opts.cwd } or nil,
  })
  local self = M.attach(shell)
  shell:activate(self)
  return self
end

return M
