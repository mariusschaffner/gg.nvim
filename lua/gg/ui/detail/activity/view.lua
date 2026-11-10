--- The Activity tab of the issue and merge request detail views: loads the
--- discussions, draws the timeline and handles its keys (expand a run or a
--- folded thread, fold threads, expand a long comment). Read-only.
local date = require("gg.ui.lib.date")
local gg = require("gg")
local model = require("gg.ui.detail.activity.model")
local picker = require("gg.ui.components.picker")
local render = require("gg.ui.detail.activity.render")

local M = {}

---@class gg.ui.ActivityTabOpts
---@field tab string the host tab key
---@field noteable "issue"|"merge_request"
---@field host string
---@field project string
---@field iid integer
---@field now? fun(): integer
---@field today? gg.ui.Date
---@field on_loaded? fun(count: integer) number of comments, after a load

---@class gg.ui.ActivityTab
---@field host gg.ui.DetailHost
---@field status "idle"|"loading"|"ready"|"error"
---@field discussions gg.Discussion[]|nil
---@field me string|nil
---@field state gg.ui.ActivityState
local Tab = {}
Tab.__index = Tab

--- Attach the Activity tab to `host` (nothing loads until `load`).
---@param host gg.ui.DetailHost
---@param opts gg.ui.ActivityTabOpts
---@return gg.ui.ActivityTab
function M.new(host, opts)
  local self = setmetatable({
    host = host,
    opts = opts,
    status = "idle",
    state = { expanded_runs = {}, expanded_notes = {}, folded = {} },
  }, Tab)
  local k = host.keys
  host:map(opts.tab, k.open_item, function()
    self:expand()
  end, "Expand")
  host:map(opts.tab, k.toggle_fold, function()
    self:toggle_fold()
  end, "Fold")
  host:map(opts.tab, k.toggle_all_folds, function()
    self:toggle_all()
  end, "Fold all")
  host:set_hints(opts.tab, {
    { key = picker.first_key(k.open_item) and picker.lhs_list(k.open_item)[#picker.lhs_list(k.open_item)], desc = "Expand" },
    { key = picker.first_key(k.toggle_fold), desc = "Fold" },
    { key = picker.first_key(k.toggle_all_folds), desc = "Fold all" },
  })
  return self
end

--- Load the discussions (and the signed-in user, once).
function Tab:load()
  self:cancel()
  self.status = "loading"
  self:render()
  local o = self.opts
  local tasks = {
    gg.notes.discussions_all(
      { host = o.host, project = o.project, iid = o.iid, noteable = o.noteable },
      { limit = self.host.cfg.limit }
    ),
  }
  if not self.me then
    table.insert(tasks, gg.users.current({ host = o.host }))
  end
  self.tasks = tasks
  tasks[1]:on_done(function(res, err)
    if self.tasks ~= tasks or self.host.closed then
      return
    end
    if err then
      self.status, self.err = "error", err.message or tostring(err)
    else
      self.status, self.discussions = "ready", res and res.items or {}
      self.truncated = res and res.truncated
      if o.on_loaded then
        o.on_loaded(self:comment_count())
      end
    end
    self:render()
  end)
  if tasks[2] then
    tasks[2]:on_done(function(user)
      if self.tasks == tasks and user and user.username then
        self.me = user.username
        self:render()
      end
    end)
  end
end

--- Number of comments (not system notes).
---@return integer
function Tab:comment_count()
  local n = 0
  for _, d in ipairs(self.discussions or {}) do
    for _, note in ipairs(d.notes or {}) do
      if not note.system then
        n = n + 1
      end
    end
  end
  return n
end

--- Cancel requests in flight.
function Tab:cancel()
  for _, t in ipairs(self.tasks or {}) do
    t:cancel()
  end
  self.tasks = nil
end

--- Redraw the tab.
function Tab:render()
  if self.host.closed then
    return
  end
  local o = self.opts
  local items
  if self.status == "ready" then
    items = model.build(self.discussions, {
      state = self.state,
      utc_offset = date.utc_offset(),
      today = o.today or date.today(),
    })
  end
  local k = self.host.keys
  local open = picker.lhs_list(k.open_item)
  local d = render.render({
    width = self.host:content_width(),
    status = self.status == "idle" and "loading" or self.status,
    items = items,
    error = self.err,
    state = self.state,
    me = self.me,
    utc_offset = date.utc_offset(),
    user_colors = self.host.cfg.user_colors,
    keys = { expand = open[#open], fold = picker.first_key(k.toggle_fold) },
  })
  self.host:set_content(o.tab, d)
end

-- re-render and put the cursor back on the line matching `pred`
function Tab:_rerender_at(pred)
  self:render()
  local d = self.host.docs[self.host:buf(self.opts.tab)]
  if not d then
    return
  end
  for lnum = 1, #d.lines do
    local info = d.rows[lnum]
    if info and pred(info) then
      self.host:set_cursor(lnum)
      return
    end
  end
end

--- `<CR>`: expand the "N more changes" run or the folded replies under the
--- cursor.
function Tab:expand()
  local info = self.host:current()
  if not info then
    return
  end
  if info.kind == "more" then
    self.state.expanded_runs[info.run] = true
    self:render()
  elseif info.kind == "replies" or (info.kind == "comment" and self.state.folded[info.thread]) then
    self.state.folded[info.thread] = nil
    local id = info.thread
    self:_rerender_at(function(i)
      return i.thread == id
    end)
  end
end

--- `za`: on a long comment, show it in full (or cut it again); elsewhere in
--- a thread, fold or unfold its replies.
function Tab:toggle_fold()
  local info = self.host:current()
  if not info or not info.thread then
    return
  end
  if info.kind == "comment" and info.long then
    local id = info.note
    self.state.expanded_notes[id] = not self.state.expanded_notes[id] or nil
    return self:_rerender_at(function(i)
      return i.note == id
    end)
  end
  local id = info.thread
  self.state.folded[id] = not self.state.folded[id] or nil
  self:_rerender_at(function(i)
    return i.thread == id
  end)
end

--- `zA`: fold every thread with replies, or unfold all when some are folded.
function Tab:toggle_all()
  local any = next(self.state.folded) ~= nil
  self.state.folded = {}
  if not any then
    for _, d in ipairs(self.discussions or {}) do
      local comments = 0
      for _, n in ipairs(d.notes or {}) do
        if not n.system then
          comments = comments + 1
        end
      end
      if comments > 1 then
        self.state.folded[d.id] = true
      end
    end
  end
  self:render()
end

return M
