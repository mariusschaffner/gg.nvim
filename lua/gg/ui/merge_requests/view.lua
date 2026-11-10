--- The merge requests view of the picker: one line per merge request of the
--- project, with Open/Merged/Closed/All tabs and client-side pages.
---
--- Loading:
---   * The list loads in three parallel streams of pages (`gg.merge_requests.list`,
---     one per state, see `gg.ui.components.streams`); rows show at once.
---   * The Pipeline and Diff cells of the rows on the visible page then fill
---     in asynchronously: `gg.merge_requests.summaries` in batches of
---     `BATCH` IIDs, at most `CONCURRENCY` requests at a time. Only those
---     lines are rewritten, so the cursor never moves.
---   * Summaries are cached per merge request for this picker, valid while
---     the MR's `updated_at` is unchanged. `R` also drops entries whose
---     pipeline was still active (running, pending, ...) and failed ones.
---   * GitLab answers `diffStatsSummary` with 0 / 0 and 0 files when it has
---     no line counts for an MR. Those diff cells fall back to
---     `gg.mr_changes.diffstat` (counts from GitLab's stored diffs; one REST
---     request per 100 files, up to `FALLBACK_FILES`), through the same queue.
---   * The signed-in user (`gg.users.current`) is drawn bold.
local cells = require("gg.ui.merge_requests.cells")
local gg = require("gg")
local highlights = require("gg.ui.highlights")
local hint = require("gg.ui.lib.hint")
local model = require("gg.ui.merge_requests.model")
local picker = require("gg.ui.components.picker")
local project = require("gg.ui.project")
local queue = require("gg.ui.components.queue")
local render = require("gg.ui.merge_requests.render")
local streams = require("gg.ui.components.streams")

local M = {}

M.BATCH = 10
M.CONCURRENCY = 4
M.FALLBACK_FILES = 300

-- pipeline statuses that can still change without the MR's updated_at changing
local ACTIVE = {
  created = true,
  waiting_for_resource = true,
  preparing = true,
  waiting_for_callback = true,
  pending = true,
  running = true,
  canceling = true,
  scheduled = true,
  manual = true,
}

---@class gg.ui.MrCacheEntry
---@field updated_at string|nil the MR's updated_at the entry was fetched for
---@field summary? gg.MergeRequestSummary nil when GitLab did not return the MR
---@field error? boolean the request failed
---@field diff? { additions: integer, deletions: integer } from the diffstat fallback
---@field diff_loading? boolean the summary had no line counts; the fallback is pending
---@field diff_error? boolean the fallback failed

---@class gg.ui.MrView
---@field name "merge_requests"
---@field shell gg.ui.Picker
---@field host string|nil
---@field project string|nil
---@field status "idle"|"loading"|"ready"|"error"
---@field tab gg.ui.MrTab
---@field query string
---@field page integer
---@field pages gg.ui.MrPage[]
---@field mrs gg.MergeRequest[]|nil every loaded merge request (all states)
---@field model gg.ui.MrModel|nil
---@field rendered gg.ui.Rendered|nil
---@field selected_iid integer|nil
---@field touched boolean
---@field cache table<integer, gg.ui.MrCacheEntry>
---@field queue gg.ui.Queue
---@field inflight table<integer, boolean> IIDs being fetched
---@field me string|nil the signed-in user's username
---@field closed boolean
local View = {}
View.__index = View

--- Create the merge requests view inside an open picker (not activated).
---@param shell gg.ui.Picker
---@return gg.ui.MrView
function M.attach(shell)
  local self = setmetatable({
    name = "merge_requests",
    filetype = "gg_ui_merge_requests",
    placeholder = "Filter",
    shell = shell,
    cfg = shell.cfg,
    keys = shell.keys,
    status = "idle",
    tab = "opened",
    query = "",
    page = 1,
    pages = { { rows = {}, count = 0 } },
    touched = false,
    closed = false,
    cache = {},
    inflight = {},
    inflight_diff = {},
    queue = queue.new({ concurrency = M.CONCURRENCY }),
    list = shell.list,
    prompt = shell.prompt,
    table_float = shell.table_float,
    filter_float = shell.filter_float,
  }, View)
  streams.init(self, model.STATES)
  shell:add(self)
  return self
end

--- Called by the picker when this view becomes active: the first time it
--- starts loading, later it redraws.
function View:activate()
  highlights.setup()
  if self.status == "idle" then
    if self.shell.host then
      self.host, self.project = self.shell.host, self.shell.project
      self:load()
    else
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

---@private
function View:_fetch_me()
  if self.me_task or self.me then
    return
  end
  self.me_task = gg.users.current({ host = self.host })
  self.me_task:on_done(function(u, err)
    if self.closed then
      return
    end
    if not err and u and u.username then
      self.me = u.username
      self:render()
    end
  end)
end

-- drop cache entries that may be stale even with the same updated_at
---@private
function View:_expire()
  for iid, e in pairs(self.cache) do
    local p = e.summary and e.summary.head_pipeline
    if e.error or e.diff_error or (p and ACTIVE[p.status]) then
      self.cache[iid] = nil
    end
  end
end

--- (Re)load the merge requests: three parallel streams (opened, merged,
--- closed), up to `limit` each. Cached cells stay unless they may be stale.
function View:load()
  if self.closed then
    return
  end
  if not self.host then
    return self:_resolve()
  end
  self:_fetch_me()
  self:_expire()
  self.queue:clear()
  streams.start(self, {
    limit = self.cfg.limit,
    has_items = self.status == "ready" and self.mrs ~= nil,
    fetch = function(state, cursor, per_page)
      return gg.merge_requests.list({
        host = self.host,
        project = self.project,
        state = state,
        order_by = "updated_at",
        sort = "desc",
      }, { per_page = per_page, cursor = cursor })
    end,
    on_start = function()
      if not self.refreshing then
        self.status, self.mrs = "loading", nil
      end
      self:render()
    end,
    on_update = function(all)
      self.mrs, self.status = all, "ready"
      self:render()
    end,
    on_error = function(err)
      self.status, self.err_msg = "error", err.message or tostring(err)
      self:render()
    end,
  })
end

-- valid cache entries by IID (the renderer shows "·" for the rest)
---@private
function View:_summaries()
  local out = {}
  for _, mr in ipairs(self.mrs or {}) do
    local e = self.cache[mr.iid]
    if e and e.updated_at == mr.updated_at then
      out[mr.iid] = e
    end
  end
  return out
end

---@private
function View:_output()
  local mdl
  if self.mrs and self.status ~= "error" then
    mdl = model.build(self.mrs, { tab = self.tab, query = self.query })
    self.pages = model.pages(mdl.rows, self.cfg.page_size)
    self.page = model.page_of(self.pages, self.selected_iid) or self.page
    self.page = math.max(1, math.min(#self.pages, self.page))
  end
  self.model = mdl
  return render.render({
    width = self.shell:width(),
    status = self.status == "idle" and "loading" or self.status,
    pending = (self.status == "ready" and not self.refreshing) and self.pending or nil,
    tab = self.tab,
    model = mdl,
    page = self.pages[self.page],
    error = self.err_msg,
    loaded = self.loaded,
    truncated = self.truncated and self.cfg.limit or nil,
    retry_key = picker.first_key(self.keys.refresh) or false,
    summaries = self:_summaries(),
    user_colors = self.cfg.user_colors,
    me = self.me,
  })
end

--- Redraw the table from the current state; the selection survives. A no-op
--- while another view is active. Then fetches the missing cells of the page.
function View:render()
  if self.closed or not self.shell:is_active(self) or not self.shell:valid() then
    return
  end
  if not self.touched then
    self.selected_iid, self.sel_row = nil, nil
  end
  local r = self:_output()
  self.rendered = r
  self.list:set(r)
  local target
  if self.selected_iid then
    for _, lnum in ipairs(r.selectable) do
      if r.rows[lnum].mr.iid == self.selected_iid then
        target = lnum
        break
      end
    end
  end
  self._rendering = true
  self.list:select(target or self.sel_row)
  self._rendering = false
  self.prompt:set_counter(nil) -- this view has no match counter
  self.shell:chrome(self:_title(), self:_footer())
  self:_fill()
end

-- Rewrite only the lines of `iids` (their cells arrived).
---@private
function View:_patch(iids)
  if self.closed or not self.shell:is_active(self) or not self.shell:valid() or not self.rendered then
    return
  end
  local r = self:_output()
  local old = self.rendered
  if #r.lines ~= #old.lines or #r.selectable ~= #old.selectable then
    return self:render()
  end
  local want, lnums = {}, {}
  for _, iid in ipairs(iids) do
    want[iid] = true
  end
  for _, lnum in ipairs(r.selectable) do
    local mr = r.rows[lnum].mr
    if want[mr.iid] then
      table.insert(lnums, lnum)
    end
  end
  self.rendered = r
  self.list:patch(r, lnums)
  self.shell:overlay(self.list:current())
end

-- Fetch the summaries the visible page still lacks.
---@private
function View:_fill()
  if self.closed or self.status ~= "ready" or not self.shell:is_active(self) then
    return
  end
  local page = self.pages[self.page]
  if not page then
    return
  end
  self.queue:clear() -- jobs for a page no longer shown
  local batch, versions = {}, {}
  local function flush()
    if #batch == 0 then
      return
    end
    local iids, at = batch, versions
    batch, versions = {}, {}
    self.queue:push(table.concat(iids, ","), function()
      for _, iid in ipairs(iids) do
        self.inflight[iid] = true
      end
      return gg.merge_requests.summaries({ host = self.host, project = self.project, iids = iids })
    end, function(res, err)
      self:_arrived(iids, at, res, err)
    end)
  end
  local fallbacks = {}
  for _, mr in ipairs(page.rows) do
    local e = self.cache[mr.iid]
    if not (e and e.updated_at == mr.updated_at) then
      if not self.inflight[mr.iid] then
        table.insert(batch, mr.iid)
        versions[mr.iid] = mr.updated_at
        if #batch >= M.BATCH then
          flush()
        end
      end
    elseif e.diff_loading and not self.inflight_diff[mr.iid] then
      table.insert(fallbacks, mr.iid)
    end
  end
  flush()
  for _, iid in ipairs(fallbacks) do
    self:_push_fallback(iid)
  end
end

-- The summary had no line counts: count them from the stored diffs.
---@private
function View:_push_fallback(iid)
  local entry = self.cache[iid]
  self.queue:push("diff:" .. iid, function()
    self.inflight_diff[iid] = true
    return gg.mr_changes.diffstat({ host = self.host, project = self.project, iid = iid }, { limit = M.FALLBACK_FILES })
  end, function(res, err)
    self.inflight_diff[iid] = nil
    if self.closed or self.cache[iid] ~= entry then
      return -- refreshed meanwhile
    end
    entry.diff_loading = nil
    if err then
      entry.diff_error = true
    else
      entry.diff = cells.sum_stats(res.items or {})
    end
    self:_patch({ iid })
  end)
end

---@private
function View:_arrived(iids, at, res, err)
  for _, iid in ipairs(iids) do
    self.inflight[iid] = nil
  end
  if self.closed then
    return
  end
  local by_iid = {}
  for _, s in ipairs(res or {}) do
    by_iid[s.iid] = s
  end
  local fallbacks = {}
  for _, iid in ipairs(iids) do
    -- keyed to the list version it was asked for, so a newer MR refetches
    local s = by_iid[iid]
    local entry = { updated_at = at[iid], summary = s, error = err ~= nil or nil }
    if s and cells.is_nil_stats(s.diff_stats) then
      entry.diff_loading = true
      table.insert(fallbacks, iid)
    end
    self.cache[iid] = entry
  end
  self:_patch(iids)
  for _, iid in ipairs(fallbacks) do
    self:_push_fallback(iid)
  end
end

---@private
function View:_title()
  if self.refreshing then
    return " Table · refreshing… "
  end
  if self.status == "ready" then
    for _, s in ipairs(model.STATES) do
      if self.pending[s] then
        return (" Table · loading… %d "):format(self.loaded)
      end
    end
  end
  return " Table "
end

---@private
function View:_footer()
  local hints = {}
  local k = picker.first_key
  if k(self.keys.inspect_mr) then
    table.insert(hints, { key = k(self.keys.inspect_mr), desc = "Merge Request" })
  end
  local pages = self.pages and #self.pages or 1
  if pages > 1 and k(self.keys.next_page) then
    table.insert(hints, { key = k(self.keys.next_page), desc = ("Page %d/%d"):format(self.page, pages) })
  end
  if self.project and k(self.keys.create) then
    table.insert(hints, { key = k(self.keys.create), desc = "Create Merge Request" })
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
  if row and row.mr then
    self.selected_iid = row.mr.iid
    self.sel_row = lnum
    if not self._rendering then
      self.touched = true
    end
  end
  self.shell:overlay(row and row.mr and lnum or nil)
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

--- Switch to the next (1) or previous (-1) tab: Open -> Merged -> Closed -> All.
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

--- Open the detail view of the merge request under the cursor.
function View:inspect_mr()
  local lnum = self.list:current()
  local row = lnum and self.rendered and self.rendered.rows[lnum]
  if row and row.mr then
    require("gg.ui.detail").merge_request(self.shell:detail_ctx(self), row.mr)
  end
end

--- `c`: the new merge request popup (source: the current git branch).
function View:create()
  if self.project then
    require("gg.ui.create").merge_request(self.shell:detail_ctx(self), { cwd = self.shell.target_opts and self.shell.target_opts.cwd or nil })
  end
end

--- The view's own table keymaps (the shell maps the shared ones).
---@return { [1]: gg.ui.Keymap, [2]: fun(), [3]: string }[]
function View:keymaps()
  local k = self.keys
  return {
    { k.create, function()
      self:create()
    end, "Create merge request" },
    { k.inspect_mr, function()
      self:inspect_mr()
    end, "Inspect merge request" },
    { k.next_page, function()
      self:next_page()
    end, "Next page" },
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
  if self.me_task then
    self.me_task:cancel()
  end
  self.queue:cancel_all()
  streams.cancel(self)
end

--- Open a picker on the merge requests view (same options as the issues
--- view's `open`).
---@param opts? { arg?: string, host?: string, project?: string, cwd?: string, config?: gg.ui.Config }
---@return gg.ui.MrView
function M.open(opts)
  opts = opts or {}
  local cfg = opts.config or require("gg.ui.config").get()
  highlights.setup()
  local direct = opts.host and opts.project
  local shell = picker.new({
    cfg = cfg,
    filetype = "gg_ui_merge_requests",
    host = direct and opts.host or nil,
    project = direct and opts.project or nil,
    target_opts = not direct and { arg = opts.arg or opts.project, cwd = opts.cwd } or nil,
  })
  local self = M.attach(shell)
  shell:activate(self)
  return self
end

return M
