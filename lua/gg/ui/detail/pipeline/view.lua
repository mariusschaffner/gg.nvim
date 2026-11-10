--- The pipeline detail view: the stage/job graph in the header, the log of
--- the selected job below it.
---
--- Two key modes on the log window: in graph mode `h` / `l` pick the
--- stage, `j` / `k` the job and `<CR>` moves into the log; in log mode the
--- usual motions and `/` work and `<Esc>` goes back to the graph. `F`
--- follows the log of a running job, `za` folds a section. Read-only.
---
--- Live while visible: the pipeline is polled while it is active
--- (`pipeline_detail_poll_ms`), its clocks tick every second, and the log
--- of a running job is tailed (`job_log_poll_ms`) with byte ranges, so
--- only new output is fetched; the buffer is rewritten from the first
--- changed line on.
local date = require("gg.ui.lib.date")
local doc = require("gg.ui.lib.doc")
local gg = require("gg")
local graph = require("gg.ui.detail.pipeline.graph")
local header = require("gg.ui.detail.header")
local highlights = require("gg.ui.highlights")
local hint = require("gg.ui.lib.hint")
local host = require("gg.ui.detail.host")
local layout = require("gg.ui.components.layout")
local log_model = require("gg.ui.detail.pipeline.log_model")
local picker = require("gg.ui.components.picker")
local status = require("gg.ui.detail.pipeline.status")

local M = {}

M.TICK_MS = 1000

-- the elapsed clock in the colour of the status
local CLOCK_HL = {
  running = "GitlabPipelineRunning",
  success = "GitlabPipelineSuccess",
  failed = "GitlabPipelineFailed",
}

---@class gg.ui.PipelineLog
---@field job gg.Job
---@field model gg.ui.LogModel
---@field offset integer bytes fetched
---@field done boolean the job finished and its log is complete
---@field error string|nil
---@field loading boolean

---@class gg.ui.PipelineDetail
---@field ctx gg.ui.DetailCtx
---@field h gg.ui.DetailHost
---@field screen gg.ui.Screen
---@field project string
---@field id integer
---@field pipeline gg.Pipeline
---@field status "loading"|"ready"|"error"
---@field sel { stage: integer, job: integer }|nil
---@field mode "graph"|"log"
---@field following boolean
---@field log gg.ui.PipelineLog|nil
local View = {}
View.__index = View

local function stop_timer(t)
  if t and not t:is_closing() then
    t:stop()
    t:close()
  end
end

--- Open the pipeline detail view (called through `gg.ui.detail.pipeline`).
---@param ctx gg.ui.DetailCtx
---@param item gg.Pipeline|{ id: integer, project?: string }
---@return gg.ui.PipelineDetail
function M.open(ctx, item)
  highlights.setup()
  local self = setmetatable({
    ctx = ctx,
    project = item.project or ctx.project,
    id = item.id,
    pipeline = vim.deepcopy(item),
    status = "loading",
    mode = "graph",
    following = true,
    timers = {},
  }, View)
  self.h = host.new({
    stack = ctx.stack,
    cfg = ctx.cfg,
    name = "pipeline",
    on_render = function()
      self:render()
    end,
    on_refresh = function()
      self:load()
    end,
  })
  self.screen = self.h.screen
  self.screen.suspend = function()
    self.suspended = true
    self:_stop_timers()
  end
  self.screen.resume = function()
    self.suspended = false
    self:load()
  end
  self.screen.teardown = function()
    self:_stop_timers()
    self:_cancel()
  end
  self.buf = self.h:buf("main")
  local win = self.h.content_float.win
  for o, v in pairs({ number = true, foldmethod = "manual", foldenable = true, foldtext = "", fillchars = "fold: ,eob: " }) do
    vim.api.nvim_set_option_value(o, v, { win = win })
  end
  self:_keymaps()
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = self.h.augroup,
    buffer = self.buf,
    callback = function()
      self:_on_cursor()
    end,
  })
  self:load()
  return self
end

-- Keys -------------------------------------------------------------------------

local GRAPH_KEYS = { "graph_left", "graph_right", "graph_down", "graph_up", "log_focus" }

---@private
function View:_keymaps()
  local h, k = self.h, self.h.keys
  h:map_all(k.log_follow, function()
    self:follow()
  end, "Follow the log")
  h:map_all(k.toggle_fold, function()
    pcall(vim.cmd, "normal! za")
  end, "Fold")
  self:_set_mode("graph")
end

---@private
function View:_map(name, fn, desc)
  for _, lhs in ipairs(picker.lhs_list(self.h.keys[name])) do
    vim.keymap.set("n", lhs, fn, { buffer = self.buf, nowait = true, silent = true, desc = desc })
  end
end

---@private
function View:_unmap(name)
  for _, lhs in ipairs(picker.lhs_list(self.h.keys[name])) do
    pcall(vim.keymap.del, "n", lhs, { buffer = self.buf })
  end
end

---@private
function View:_set_mode(mode)
  self.mode = mode
  if mode == "graph" then
    self:_unmap("graph_back")
    self:_map("graph_left", function()
      self:move_stage(-1)
    end, "Previous stage")
    self:_map("graph_right", function()
      self:move_stage(1)
    end, "Next stage")
    self:_map("graph_down", function()
      self:move_job(1)
    end, "Next job")
    self:_map("graph_up", function()
      self:move_job(-1)
    end, "Previous job")
    self:_map("log_focus", function()
      self:_set_mode("log")
    end, "Into the log")
  else
    for _, name in ipairs(GRAPH_KEYS) do
      self:_unmap(name)
    end
    self:_map("graph_back", function()
      self:_set_mode("graph")
    end, "Back to the graph")
  end
  self:render_header()
  self:_log_chrome()
end

-- Loading ----------------------------------------------------------------------

---@private
function View:_cancel()
  for _, name in ipairs({ "graph", "trace" }) do
    if self[name .. "_task"] then
      self[name .. "_task"]:cancel()
      self[name .. "_task"] = nil
    end
  end
end

---@private
function View:_args(extra)
  return vim.tbl_extend("force", { host = self.ctx.host, project = self.project }, extra or {})
end

--- (Re)load the pipeline graph; the selection stays on the same job.
function View:load()
  if self.h.closed then
    return
  end
  if self.graph_task then
    return
  end
  local t = gg.pipelines.graph(self:_args({ id = self.id }))
  self.graph_task = t
  t:on_done(function(p, err)
    if self.h.closed or self.graph_task ~= t then
      return
    end
    self.graph_task = nil
    if err then
      if self.status ~= "ready" then
        self.status, self.err = "error", err.message or tostring(err)
      end
      self:render()
      return
    end
    self:_update(p)
  end)
  self:render()
end

-- the job at the selection
---@private
function View:_job()
  local sel = self.sel
  local st = sel and self.pipeline.stages and self.pipeline.stages[sel.stage]
  return st and st.jobs and st.jobs[sel.job] or nil
end

-- a fresh pipeline arrived: keep the selection on the same job (by stage
-- and job name: a retried job has a new id)
---@private
function View:_update(p)
  local old = self:_job()
  local old_stage = self.sel and self.pipeline.stages and self.pipeline.stages[self.sel.stage]
  self.pipeline, self.status, self.err = p, "ready", nil
  local found
  if old and old_stage then
    for si, st in ipairs(p.stages or {}) do
      for ji, j in ipairs(st.jobs or {}) do
        if st.name == old_stage.name and j.name == old.name then
          found = { stage = si, job = ji }
        end
      end
    end
  end
  if found then
    self.sel = found
  else
    local si, ji = status.default_job(p.stages)
    self.sel = si and { stage = si, job = ji } or nil
  end
  local job = self:_job()
  if not job then
    self.log = nil
  elseif not self.log or self.log.job.id ~= job.id then
    self:_select_log(job)
  else
    local was_active = status.is_active(self.log.job.status)
    self.log.job = job
    if was_active and not status.is_active(job.status) then
      self:fetch_trace(true) -- the last of the log
    end
  end
  self:render()
  self:_sync_timers()
end

-- start over with the log of `job`
---@private
function View:_select_log(job)
  if self.trace_task then
    self.trace_task:cancel()
    self.trace_task = nil
  end
  self.log = { job = job, model = log_model.new(), offset = 0, done = false, loading = false }
  self.shown = nil
  self.positioned = false
  self.following = status.is_active(job.status)
  self:fetch_trace()
end

-- statuses whose job has run (and so has a log), even without started_at
local RAN = { running = true, success = true, failed = true, canceled = true, canceling = true }

local function started(job)
  return job.started_at ~= nil or RAN[(job.status or ""):lower()] == true
end

--- Fetch the selected job's log (the new part of it); `final` after the
--- job has finished.
---@param final? boolean
function View:fetch_trace(final)
  local log = self.log
  if not log or log.done then
    return
  end
  if not started(log.job) then
    self:render_log()
    return
  end
  if self.trace_task then
    self.pending_final = self.pending_final or final
    return
  end
  local offset = log.offset
  local chunks = {}
  log.loading = offset == 0
  local t = gg.jobs.trace(self:_args({
    id = log.job.id,
    offset = offset > 0 and offset or nil,
    on_chunk = function(data)
      if offset == 0 then
        log.model:feed(data)
      else
        table.insert(chunks, data)
      end
    end,
  }))
  self.trace_task = t
  t:on_done(function(res, err)
    if self.h.closed or self.trace_task ~= t or self.log ~= log then
      return
    end
    self.trace_task = nil
    log.loading = false
    if err then
      log.error = err.message or tostring(err)
    else
      log.error = nil
      if offset > 0 and res.range_ignored then
        -- the server sent the whole log: start over with it
        log.model = log_model.new()
        self.shown = nil
        log.offset = 0
      end
      for _, c in ipairs(chunks) do
        log.model:feed(c)
      end
      log.offset = log.offset + (res.bytes or 0)
      if not status.is_active(log.job.status) then
        log.model:finish()
        log.done = true
      end
    end
    self:render_log()
    if self.pending_final then
      self.pending_final = false
      self:fetch_trace(true)
    end
  end)
  if offset == 0 then
    self:render_log()
  end
end

-- Timers -----------------------------------------------------------------------

---@private
function View:_stop_timers()
  for k, t in pairs(self.timers) do
    stop_timer(t)
    self.timers[k] = nil
  end
end

---@private
function View:_timer(name, ms, fn)
  if self.timers[name] or ms <= 0 then
    return
  end
  local t = vim.uv.new_timer()
  self.timers[name] = t
  t:start(ms, ms, vim.schedule_wrap(function()
    if self.h.closed or self.suspended then
      return self:_stop_timers()
    end
    fn()
  end))
end

---@private
function View:_sync_timers()
  if self.h.closed or self.suspended then
    return
  end
  local cfg = self.ctx.cfg
  local active = status.is_active(self.pipeline.status)
  if active then
    self:_timer("poll", cfg.pipeline_detail_poll_ms or 0, function()
      self:load()
    end)
    self:_timer("tick", M.TICK_MS, function()
      self:render_header()
    end)
  else
    stop_timer(self.timers.poll)
    stop_timer(self.timers.tick)
    self.timers.poll, self.timers.tick = nil, nil
  end
  local job = self:_job()
  if job and status.is_active(job.status) and started(job) then
    self:_timer("trace", cfg.job_log_poll_ms or 0, function()
      self:fetch_trace()
    end)
  else
    stop_timer(self.timers.trace)
    self.timers.trace = nil
  end
end

-- Selection --------------------------------------------------------------------

--- Previous (-1) or next (1) stage with jobs; the job index is kept
--- (clamped).
---@param dir integer
function View:move_stage(dir)
  local stages = self.pipeline.stages or {}
  if not self.sel then
    return
  end
  local i = self.sel.stage + dir
  while stages[i] do
    if stages[i].jobs and #stages[i].jobs > 0 then
      self:_select({ stage = i, job = math.min(self.sel.job, #stages[i].jobs) })
      return
    end
    i = i + dir
  end
end

--- Next (1) or previous (-1) job of the stage.
---@param dir integer
function View:move_job(dir)
  local st = self.sel and self.pipeline.stages[self.sel.stage]
  if not st then
    return
  end
  local j = self.sel.job + dir
  if j >= 1 and j <= #st.jobs then
    self:_select({ stage = self.sel.stage, job = j })
  end
end

---@private
function View:_select(sel)
  self.sel = sel
  local job = self:_job()
  if job and (not self.log or self.log.job.id ~= job.id) then
    self:_select_log(job)
  end
  self:render()
  self:_sync_timers()
end

--- `F`: follow the log (jump to its end).
function View:follow()
  self.following = true
  self:_to_end()
  self:_log_chrome()
end

---@private
function View:_to_end()
  local win = self.h.content_float.win
  if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == self.buf then
    self._moving = true
    pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(self.buf), 0 })
    self._moving = false
  end
end

---@private
function View:_on_cursor()
  if self._moving or not self.following then
    return
  end
  local win = self.h.content_float.win
  if vim.api.nvim_win_get_cursor(win)[1] < vim.api.nvim_buf_line_count(self.buf) then
    self.following = false
    self:_log_chrome()
  end
end

-- Rendering --------------------------------------------------------------------

--- Redraw the header and the log.
function View:render()
  if self.h.closed then
    return
  end
  self:render_header()
  self:render_log()
end

---@private
function View:_now()
  return self.ctx.now and self.ctx.now() or os.time()
end

--- Redraw the header (title, graph, hints).
function View:render_header()
  local h = self.h
  if h.closed then
    return
  end
  local p = self.pipeline
  local now = self:_now()
  local width = h:header_width()
  local extra
  if self.status == "loading" then
    extra = doc.new()
    extra:text(" Loading pipeline…", "GitlabDetailMuted")
  elseif self.status == "error" then
    extra = doc.new()
    extra:text(" " .. (self.err or "Failed to load the pipeline"), "GitlabDetailError")
  else
    local g, start = graph.render({
      stages = p.stages,
      width = width - 2,
      selected = self.sel,
      focus = self.mode == "graph",
      now = now,
      start = self.graph_start,
      -- the header also holds two padding lines, the title and a blank line
      max_rows = layout.header_max() - 4,
    })
    self.graph_start = start
    extra = g
  end
  local done, total = 0, 0
  for _, st in ipairs(p.stages or {}) do
    for _, j in ipairs(st.jobs or {}) do
      total = total + 1
      if not status.is_active(j.status) and j.status ~= "manual" then
        done = done + 1
      end
    end
  end
  local right = {}
  local secs = status.elapsed(p, now)
  if secs then
    table.insert(right, { date.clock(secs), CLOCK_HL[(p.status or ""):lower()] or "GitlabDetailValue" })
    table.insert(right, { status.is_active(p.status) and " elapsed" or " total", "GitlabDetailMuted" })
  end
  if total > 0 then
    table.insert(right, { (" · %d/%d jobs"):format(done, total), "GitlabDetailMuted" })
  end
  local title = (p.merge_request and p.merge_request.title) or p.commit_title or ("Pipeline #" .. tostring(p.id))
  local body = header.build({
    width = width,
    pill = status.pill(p.status),
    title = title,
    ref = "#" .. tostring(p.id),
    title_right = right,
    extra = extra,
  })
  local meta = {}
  if p.ref then
    table.insert(meta, { "⎇ " .. p.ref, "GitlabBranchSource" })
  end
  if p.short_sha or p.sha then
    table.insert(meta, { (#meta > 0 and " · " or "") .. (p.short_sha or p.sha:sub(1, 8)), "GitlabDetailMeta" })
  end
  if p.merge_request then
    table.insert(meta, { " · !" .. p.merge_request.iid, "GitlabDetailMeta" })
  end
  if p.user then
    table.insert(meta, { " · " .. p.user.username, "GitlabDetailMeta" })
  end
  local at = p.started_at or p.created_at
  if at then
    local age = date.age(at, now)
    table.insert(meta, { " · started " .. (age == "now" and "just now" or (age .. " ago")), "GitlabDetailMeta" })
  end
  local k = h.keys
  local hints = {}
  if self.mode == "graph" then
    local function pair(a, b)
      local ka, kb = picker.first_key(k[a]), picker.first_key(k[b])
      return ka and kb and (ka .. "/" .. kb) or ka or kb
    end
    hints = {
      { key = pair("graph_left", "graph_right"), desc = "Stage" },
      { key = pair("graph_down", "graph_up"), desc = "Job" },
      { key = picker.first_key(k.log_focus), desc = "Log" },
    }
  else
    hints = { { key = picker.first_key(k.graph_back), desc = "Graph" } }
  end
  hints = vim.tbl_filter(function(x)
    return x.key ~= nil
  end, hints)
  h:set_header(body, header.border_title(width, header.crumb("pipelines"), "#" .. tostring(p.id), meta), hint.chunks(hints))
end

-- the content window's title and footer
---@private
function View:_log_chrome()
  local h = self.h
  if h.closed then
    return
  end
  local job = self.log and self.log.job
  local title = { { " ", nil } }
  if job then
    local b = status.job_badge(job, self:_now())
    table.insert(title, { b.icon .. " ", b.icon_hl })
    table.insert(title, { job.name .. " ", "GitlabDetailTitle" })
    if self.following and status.is_active(job.status) then
      table.insert(title, { " ● following ", "GitlabBadgeFollow" })
    end
  else
    title = " Log "
  end
  h:set_title(title)
  local k = h.keys
  local hints = {
    { key = picker.first_key(k.log_follow), desc = "Follow" },
    { key = "/", desc = "Search" },
    { key = picker.first_key(k.toggle_fold), desc = "Fold" },
  }
  h:set_hints("main", hints)
end

local function message(s, hl)
  local d = doc.new()
  d:text(" " .. s, hl or "GitlabDetailMuted")
  return d
end

--- Redraw the log: only the lines from the first change on.
function View:render_log()
  local h = self.h
  if h.closed then
    return
  end
  self:_log_chrome()
  local log = self.log
  local msg
  if self.status == "loading" and not log then
    msg = message("Loading…")
  elseif not log then
    msg = message("No job selected.")
  elseif log.error and log.model:empty() then
    msg = message("Failed to load the job log: " .. log.error, "GitlabDetailError")
  elseif not started(log.job) then
    msg = message("This job hasn't started yet.")
  elseif log.loading and log.model:empty() then
    msg = message("Loading log…")
  elseif log.model:empty() and log.done then
    msg = message("(empty log)")
  end
  if msg then
    h:write(self.buf, msg)
    self.shown = nil
    return
  end
  local d, folds = log.model:render()
  local old = self.shown or {}
  local first = log_model.first_diff(old, d.lines)
  if self.shown == nil then
    h:write(self.buf, d)
    first = 1
  elseif first then
    local buf = self.buf
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, first - 1, -1, false, vim.list_slice(d.lines, first))
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, h.ns, first - 1, -1)
    for _, l in ipairs(d.line_hls) do
      if l.row >= first - 1 then
        pcall(vim.api.nvim_buf_set_extmark, buf, h.ns, l.row, 0, { line_hl_group = l.hl, priority = 10 })
      end
    end
    for _, m in ipairs(d.marks) do
      if m.row >= first - 1 then
        pcall(vim.api.nvim_buf_set_extmark, buf, h.ns, m.row, m.col, { end_col = m.end_col, hl_group = m.hl, strict = false })
      end
    end
    h.docs[buf] = d
  end
  self.shown = d.lines
  if first then
    self:_folds(folds)
  end
  -- the running job's tail
  local win = h.content_float.win
  if status.is_active(log.job.status) then
    pcall(vim.api.nvim_buf_set_extmark, self.buf, h.ns, #d.lines - 1, 0, { virt_text = { { "▌", "GitlabLogTail" } }, virt_text_pos = "eol" })
  end
  if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == self.buf then
    if self.following then
      self:_to_end()
    elseif not self.positioned then
      self.positioned = true
      self._moving = true
      local target = log.job.status == "failed" and log.model.first_error or #d.lines
      pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd("normal! zz")
      end)
      self._moving = false
    end
  end
end

-- (re)create the section folds, all open except those the user closed
---@private
function View:_folds(folds)
  local key = vim.inspect(folds)
  if key == self.fold_key then
    return
  end
  self.fold_key = key
  local win = self.h.content_float.win
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= self.buf then
    return
  end
  pcall(vim.api.nvim_win_call, win, function()
    local closed = {}
    for _, f in ipairs(self.folds or {}) do
      if vim.fn.foldclosed(f[1]) == f[1] then
        closed[f[1]] = true
      end
    end
    vim.cmd("silent! normal! zE")
    for _, f in ipairs(folds) do
      vim.cmd(("silent! %d,%dfold"):format(f[1], f[2]))
    end
    vim.cmd("silent! normal! zR")
    for _, f in ipairs(folds) do
      if closed[f[1]] then
        vim.cmd(("silent! %dfoldclose"):format(f[1]))
      end
    end
  end)
  self.folds = folds
end

return M
