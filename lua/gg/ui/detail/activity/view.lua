--- The Activity tab of the issue and merge request detail views: loads the
--- discussions, draws the timeline and handles its keys (expand a run or a
--- folded thread, fold threads, expand a long comment) and the comment
--- keys: `i` comment (the box at the end), `gc` reply, `gE` edit and `gD`
--- delete your own comment, `gX` resolve / unresolve the thread.
local avatar = require("gg.ui.lib.avatar")
local composer = require("gg.ui.components.composer")
local confirm = require("gg.ui.components.confirm")
local date = require("gg.ui.lib.date")
local edit = require("gg.ui.detail.edit")
local editing = require("gg.ui.detail.editing")
local edits = require("gg.ui.detail.edits")
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
---@field can_comment? fun(): boolean the item takes comments (open)
---@field item? fun(): table the issue / merge request (mention candidates)
---@field changed? fun() a comment changed (tell the screens below)

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
  -- after open_item: `i` comments here, `<CR>` expands
  host:map(opts.tab, k.comment, function()
    self:comment()
  end, "Comment")
  host:map(opts.tab, k.reply, function()
    self:reply()
  end, "Reply")
  host:map(opts.tab, k.edit_comment, function()
    self:edit_comment()
  end, "Edit the comment")
  host:map(opts.tab, k.delete_comment, function()
    self:delete_comment()
  end, "Delete the comment")
  host:map(opts.tab, k.toggle_resolved, function()
    self:toggle_resolved()
  end, "Resolve / unresolve")
  host:set_hints(opts.tab, {}) -- the timeline shows its own key hints
  editing.cursor_hint(host, opts.tab, function(info)
    return self:_hint(info)
  end)
  return self
end

---@private
function Tab:_open()
  return not self.opts.can_comment or self.opts.can_comment()
end

-- the note and its discussion behind a timeline row
---@private
function Tab:_find(info)
  for _, d in ipairs(self.discussions or {}) do
    if d.id == info.thread then
      for _, n in ipairs(d.notes or {}) do
        if n.id == info.note then
          return n, d
        end
      end
      return nil, d
    end
  end
end

-- "[gc] reply · [gE] edit · [gD] delete · [gX] resolve" on comment rows
---@private
function Tab:_hint(info)
  if info.kind ~= "comment" or not self:_open() then
    return nil
  end
  local note, d = self:_find(info)
  if not d then
    return nil
  end
  local k = self.host.keys
  local fk = require("gg.ui.components.picker").first_key
  local parts = { { fk(k.reply), "reply" } }
  if note and self.me and note.author and note.author.username == self.me then
    table.insert(parts, { fk(k.edit_comment), "edit" })
    table.insert(parts, { fk(k.delete_comment), "delete" })
  end
  if d.resolvable then
    table.insert(parts, { fk(k.toggle_resolved), d.resolved and "unresolve" or "resolve" })
  end
  local chunks = {}
  for _, p in ipairs(parts) do
    if p[1] then
      if #chunks > 0 then
        table.insert(chunks, { " · ", "GitlabHintText" })
      end
      table.insert(chunks, { "[" .. p[1] .. "]", "GitlabHintKey" })
      table.insert(chunks, { " " .. p[2], "GitlabHintText" })
    end
  end
  return #chunks > 0 and chunks or nil
end

---@private
function Tab:_args(extra)
  local o = self.opts
  return vim.tbl_extend("force", { host = o.host, project = o.project, iid = o.iid, noteable = o.noteable }, extra or {})
end

---@private
function Tab:_mentions()
  local item = self.opts.item and self.opts.item() or {}
  return edits.mentions(item, self.discussions)
end

-- after a change: reload, put the cursor on note `follow`, tell the view
---@private
function Tab:_done(follow)
  self.follow = follow
  self:load()
  if self.opts.changed then
    self.opts.changed()
  end
end

-- open a composer; `post(text, resolve)` returns the task and the note id
-- to follow afterwards
---@private
function Tab:_compose(o)
  local h = self.host
  if h.editing then
    return edit.refuse("Finish the current edit first")
  end
  if not self:_open() then
    return edit.refuse("Commenting is closed")
  end
  h:begin_edit({ kind = "composer" })
  return composer.open({
    win = h.content_float.win,
    place = o.place,
    col = o.col,
    width = o.width or h:content_width(),
    text = o.text,
    title = o.title,
    placeholder = o.placeholder,
    keys = h.keys,
    resolve = o.resolve,
    mentions = function()
      return self:_mentions()
    end,
    group = h.group,
    on_submit = function(text, resolve, done)
      edit.run({
        what = o.what,
        busy = o.busy,
        success = o.success,
        task = function()
          return o.post(text, resolve)
        end,
        alive = function()
          return not h.closed
        end,
        apply = function(res)
          self:_done(o.follow and o.follow(res) or nil)
        end,
        done = function(_, err)
          done(err == nil)
        end,
      })
    end,
    on_close = function()
      h:end_edit()
      self:render()
    end,
  })
end

--- `i`: write a new comment (the composer docked at the bottom of the tab).
function Tab:comment()
  return self:_compose({
    what = "comment",
    busy = "Adding the comment…",
    success = "Comment added",
    title = "Comment",
    placeholder = "write a comment · markdown, @ to mention",
    post = function(text)
      return gg.notes.add(self:_args({ body = text }))
    end,
    follow = function(d)
      return d and d.notes and d.notes[1] and d.notes[1].id
    end,
  })
end

-- the last row of thread `id` (0-based buffer line) in the tab
---@private
function Tab:_thread_end(id)
  local d = self.host.docs[self.host:buf(self.opts.tab)]
  local last
  for lnum = 1, d and #d.lines or 0 do
    local info = d.rows[lnum]
    if info and info.thread == id and info.kind ~= "gap" then
      last = lnum
    end
  end
  return last and (last - 1) or nil
end

--- `gc`: reply to the thread under the cursor (under it, `@author` seeded
--- when the comment is someone else's).
function Tab:reply()
  local info = self.host:current()
  if not (info and info.thread and info.kind ~= "event") then
    return
  end
  local note, d = self:_find(info)
  if not d then
    return
  end
  local seed = ""
  local who = note and note.author and note.author.username
  if who and who ~= self.me then
    seed = "@" .. who .. " "
  end
  local after = self:_thread_end(d.id)
  return self:_compose({
    what = "reply",
    busy = "Sending the reply…",
    success = "Reply added",
    title = "↩ Reply to thread",
    placeholder = "write a reply · markdown, @ to mention",
    text = seed,
    place = after and { bufpos = after } or nil,
    col = 6,
    width = math.floor(self.host:content_width() * 0.9) - 6,
    resolve = d.resolvable and not d.resolved,
    post = function(text, resolve)
      local t = gg.notes.reply(self:_args({ discussion_id = d.id, body = text }))
      if not resolve then
        return t
      end
      return gg.task.run(function()
        local n, err = t:await()
        if err then
          return nil, err
        end
        local _, rerr = gg.notes.set_resolved(self:_args({ discussion_id = d.id, resolved = true })):await()
        if rerr then
          return nil, rerr
        end
        return n
      end)
    end,
    follow = function(n)
      return n and n.id
    end,
  })
end

-- the comment under the cursor when it is yours
---@private
function Tab:_own()
  local info = self.host:current()
  if not (info and info.kind == "comment") then
    return nil
  end
  local note, d = self:_find(info)
  if not note then
    return nil
  end
  if not (self.me and note.author and note.author.username == self.me) then
    edit.refuse("Only your own comments can be changed")
    return nil
  end
  return note, d, info
end

--- `gE`: edit your comment under the cursor, in place of its body.
function Tab:edit_comment()
  local note, d = self:_own()
  if not note then
    return
  end
  -- over the comment: below its header row
  local doc_ = self.host.docs[self.host:buf(self.opts.tab)]
  local head
  for lnum = 1, doc_ and #doc_.lines or 0 do
    local info = doc_.rows[lnum]
    if info and info.note == note.id then
      head = lnum - 1
      break
    end
  end
  return self:_compose({
    what = "comment",
    busy = "Editing the comment…",
    success = "Comment updated",
    title = "✎ Edit comment",
    text = note.body or "",
    place = head and { bufpos = head } or nil,
    col = 2,
    width = math.floor(self.host:content_width() * 0.9) - 2,
    post = function(text)
      return gg.notes.edit(self:_args({ note_id = note.id, discussion_id = d.id, body = text }))
    end,
    follow = function()
      return note.id
    end,
  })
end

--- `gD`: delete your comment under the cursor (asks first).
function Tab:delete_comment()
  local note, d = self:_own()
  if not note then
    return
  end
  confirm.ask("Delete comment?", function()
    edit.run({
      what = "comment",
      busy = "Deleting the comment…",
      success = "Comment deleted",
      task = function()
        return gg.notes.delete(self:_args({ note_id = note.id, discussion_id = d.id }))
      end,
      alive = function()
        return not self.host.closed
      end,
      apply = function()
        self:_done(nil)
      end,
    })
  end)
end

--- `gX`: resolve or unresolve the thread under the cursor.
function Tab:toggle_resolved()
  local info = self.host:current()
  if not (info and info.thread) then
    return
  end
  local _, d = self:_find(info)
  if not d then
    return
  end
  if not d.resolvable then
    return edit.refuse("This thread cannot be resolved")
  end
  local resolve = not d.resolved
  edit.run({
    what = "thread",
    busy = resolve and "Resolving the thread…" or "Reopening the thread…",
    success = resolve and "Thread resolved" or "Thread reopened",
    task = function()
      return gg.notes.set_resolved(self:_args({ discussion_id = d.id, resolved = resolve }))
    end,
    alive = function()
      return not self.host.closed
    end,
    apply = function()
      d.resolved = resolve
      self:_done(nil)
    end,
  })
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
    end
    self:render()
    if self.follow then
      local id = self.follow
      self.follow = nil
      self:_rerender_at(function(i)
        return i.note == id
      end)
    end
  end)
  if tasks[2] then
    tasks[2]:on_done(function(user)
      if self.tasks == tasks and user and user.username then
        self.me = user.username
        self.me_name = user.name
        self:render()
      end
    end)
  end
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
  -- the collapsed comment box, pinned to the bottom of the tab
  local dock = self:_open() and self.status == "ready" and render.dock({
    initials = avatar.initials(self.me_name or self.me or "you"),
    key = picker.first_key(k.comment),
  }, self.host:content_width() - 2) or nil
  self.host:set_dock(o.tab, dock)
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
