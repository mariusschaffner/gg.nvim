--- The review of a merge request: its changed files on the left, the diff
--- of one file on the right, with the threads under the lines they are on.
---
--- Keys in the diff: `gf` / `[f` files, `]h` / `[h` hunks, `]c` / `[c`
--- threads, `za` / `zA` expand unchanged lines (the file's content is
--- fetched once), `i` comment on the line (or the visual selection), `gc`
--- reply, `gE` / `gD` edit / delete, `gX` resolve, `gx` viewed, `gV` side
--- by side (the files and threads panes hidden; `<Tab>` switches between
--- the two boxes), `gs` submit the review. Comments are added to the pending review (draft notes);
--- `post_now` in the composer posts one at once. In the files pane `<CR>`
--- opens a file and `i` comments on the whole file.
local activity_render = require("gg.ui.detail.activity.render")
local confirm = require("gg.ui.components.confirm")
local date = require("gg.ui.lib.date")
local doc = require("gg.ui.lib.doc")
local edit = require("gg.ui.detail.edit")
local editing = require("gg.ui.detail.editing")
local edits = require("gg.ui.detail.edits")
local files_pane = require("gg.ui.detail.review.files")
local float = require("gg.ui.components.float")
local gg = require("gg")
local header = require("gg.ui.detail.header")
local highlights = require("gg.ui.highlights")
local hint = require("gg.ui.lib.hint")
local layout = require("gg.ui.components.layout")
local host = require("gg.ui.detail.host")
local model = require("gg.ui.detail.review.model")
local mr_render = require("gg.ui.detail.merge_request.render")
local picker = require("gg.ui.components.picker")
local position = require("gg.ui.detail.review.position")
local render = require("gg.ui.detail.review.render")
local submit = require("gg.ui.detail.review.submit")
local thread_list = require("gg.ui.detail.review.thread_list")
local threads = require("gg.ui.detail.review.threads")
local viewed = require("gg.ui.detail.review.viewed")

local M = {}

M.TAB = "main"
M.SYNTAX_MAX_LINES = 5000
M.CONTEXT_LINES = 3

local PANE_WIN_OPTS = {
  wrap = false,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  spell = false,
  list = false,
  cursorline = true,
}

---@class gg.ui.ReviewItem
---@field mr gg.MergeRequest|{ iid: integer, project?: string }
---@field path? string the file to open on

---@class gg.ui.Review
---@field ctx gg.ui.DetailCtx
---@field h gg.ui.DetailHost
---@field screen gg.ui.Screen
---@field mr gg.MergeRequest
---@field list gg.ui.ReviewFile[]
---@field idx integer the file shown
local View = {}
View.__index = View

local function fk(k)
  return picker.first_key(k)
end

--- Open the review of a merge request (called through `gg.ui.detail.review`).
---@param ctx gg.ui.DetailCtx
---@param item gg.ui.ReviewItem
---@return gg.ui.Review
function M.open(ctx, item)
  highlights.setup()
  local mr = item.mr
  local self = setmetatable({
    ctx = ctx,
    project = mr.project or ctx.project,
    iid = mr.iid,
    mr = vim.deepcopy(mr),
    full = false,
    want_path = item.path,
    status = "loading",
    list = {},
    idx = 1,
    tasks = {},
    viewed = {},
    collapsed = {}, -- directory path -> closed in the files pane
    expanded = {}, -- path -> gap index -> true
    content = {}, -- path -> { status, lines }
    tstate = { folded = {}, expanded_notes = {} },
    syn_ns = vim.api.nvim_create_namespace("gg.ui.review.syntax"),
  }, View)
  self.h = host.new({
    stack = ctx.stack,
    cfg = ctx.cfg,
    name = "review",
    sidebar = true,
    sidebar_left = true,
    sidebar_focus = true,
    gap = 0,
    -- the side pane is two boxes: the files, and the threads below them
    rects = function(r)
      if r.sidebar then
        r.sidebar, r.threads = layout.split(r.sidebar)
      end
      -- side by side: the old file in the content box, the new one beside it
      if self.split and r.content then
        r.content, r.right = M.halves(r.content)
      end
      return r
    end,
    on_sidebar = function(f)
      self:_side_maps(f.buf)
    end,
    on_render = function()
      self:render()
    end,
    on_refresh = function()
      self:load()
    end,
  })
  self.screen = self.h.screen
  self.screen.teardown = function()
    self:_cancel()
  end
  self:_maps()
  self:load()
  return self
end

--- A box's rect split into two boxes side by side (borders included).
---@param rect gg.ui.Rect
---@return gg.ui.Rect left
---@return gg.ui.Rect right
function M.halves(rect)
  local border = 2
  local lw = math.max(1, math.floor((rect.width - border) / 2))
  return { row = rect.row, col = rect.col, width = lw, height = rect.height },
    { row = rect.row, col = rect.col + lw + border, width = math.max(1, rect.width - lw - border), height = rect.height }
end

---@private
function View:_args(extra)
  return vim.tbl_extend("force", { host = self.ctx.host, project = self.project, iid = self.iid }, extra or {})
end

---@private
function View:_file()
  return self.list[self.idx]
end

---@private
function View:_head()
  local refs = self.mr.diff_refs
  return (refs and refs.head_sha) or self.mr.sha
end

-- ---------------------------------------------------------------- keys

---@private
function View:_maps()
  local h, k = self.h, self.h.keys
  local function m(key, fn, desc)
    h:map_all(key, fn, desc)
  end
  m(k.next_file, function()
    self:step_file(1)
  end, "Next file")
  m(k.prev_file, function()
    self:step_file(-1)
  end, "Previous file")
  m(k.next_hunk, function()
    self:jump("hunk", 1)
  end, "Next hunk")
  m(k.prev_hunk, function()
    self:jump("hunk", -1)
  end, "Previous hunk")
  m(k.next_thread, function()
    self:jump("thread", 1)
  end, "Next thread")
  m(k.prev_thread, function()
    self:jump("thread", -1)
  end, "Previous thread")
  m(k.review_focus, function()
    if self.split then
      -- side by side: the other box, on the same line
      self:switch_side()
    elseif h:has_sidebar() then
      h.group:focus("sidebar")
    end
  end, "Files / other side")
  m(k.pick_file, function()
    self:pick_file()
  end, "Pick a file")
  m(k.open_item, function()
    self:toggle_fold()
  end, "Expand")
  m(k.toggle_fold, function()
    self:toggle_fold()
  end, "Expand / fold")
  m(k.toggle_all_folds, function()
    self:toggle_all()
  end, "Expand the whole file")
  -- after open_item: `i` comments, `<CR>` expands
  m(k.comment, function()
    self:comment()
  end, "Comment")
  m(k.reply, function()
    self:reply()
  end, "Reply")
  m(k.edit_comment, function()
    self:edit_comment()
  end, "Edit the comment")
  m(k.delete_comment, function()
    self:delete_comment()
  end, "Delete the comment")
  m(k.toggle_resolved, function()
    self:toggle_resolved()
  end, "Resolve / unresolve")
  m(k.toggle_viewed, function()
    self:toggle_viewed()
  end, "Viewed")
  m(k.submit_review, function()
    self:submit()
  end, "Submit the review")
  m(k.toggle_split, function()
    self:toggle_split()
  end, "Side by side / unified")
  self._hints = {}
  self:_box_setup(M.TAB, function()
    return h.content_float.win
  end, "content")
  -- side by side: the boxes scroll together; the focused one has the hints
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = h.augroup,
    callback = function(ev)
      local win = tonumber(ev.match)
      for _, p in ipairs(self:_panes()) do
        if p.win == win then
          self:_follow(p)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = h.augroup,
    callback = function()
      if not self.split or h.closed then
        return
      end
      local cur = vim.api.nvim_get_current_win()
      for _, p in ipairs(self:_panes()) do
        if p.win == cur then
          self.last_pane = p.name
          self:_chrome(self.status == "ready" and self:_file() or nil)
          self:_draw_hints()
        end
      end
    end,
  })
end

-- the keys of the files pane (its buffer is new after every resize)
---@private
function View:_side_maps(buf)
  local k = self.ctx.cfg.keymaps
  local function m(key, fn, desc)
    for _, lhs in ipairs(picker.lhs_list(key)) do
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
  end
  m(k.close, function()
    self.ctx.stack:pop()
  end, "Back")
  m(k.close_all, function()
    self.ctx.stack:close()
  end, "Close")
  m(k.refresh, function()
    self:load()
  end, "Reload")
  m(k.open_item, function()
    self:_side_open(true)
  end, "Open the file")
  m(k.review_focus, function()
    self.h.group:focus(self.h.group.members.threads and "threads" or "content")
  end, "Threads")
  m(k.toggle_fold, function()
    self:_side_open(false)
  end, "Open / close the directory")
  -- after open_item: `i` comments on the file, `<CR>` opens it
  m(k.comment, function()
    if self:_side_open(false) then
      self:comment_file()
    end
  end, "Comment on the file")
  m(k.toggle_viewed, function()
    if self:_side_open(false) then
      self:toggle_viewed()
    end
  end, "Viewed")
  m(k.submit_review, function()
    self:submit()
  end, "Submit the review")
  m(k.pick_file, function()
    self:pick_file()
  end, "Pick a file")
  m(k.next_file, function()
    self:step_file(1)
  end, "Next file")
  m(k.prev_file, function()
    self:step_file(-1)
  end, "Previous file")
  m(k.toggle_split, function()
    self:toggle_split()
  end, "Side by side")
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      -- moving through the files shows them
      local info = self:_side_info()
      if info and info.kind == "file" and info.index ~= self.idx and not self.h.editing then
        self:show(info.index, { keep_side = true })
      end
    end,
  })
end

---@private
function View:_side_info()
  local f = self.h.sidebar_float
  if not (f and vim.api.nvim_win_is_valid(f.win)) then
    return nil
  end
  local d = self.h.docs[f.buf]
  return d and d.rows[vim.api.nvim_win_get_cursor(f.win)[1]] or nil
end

-- show the file under the cursor of the files pane; true when there is one
---@private
function View:_side_open(focus)
  local info = self:_side_info()
  if info and info.kind == "dir" then
    self.collapsed[info.path] = not self.collapsed[info.path] or nil
    self:_side()
    return false
  end
  if not (info and info.kind == "file") then
    return false
  end
  if info.index ~= self.idx then
    self:show(info.index, { keep_side = true })
  end
  if focus then
    self.h.group:focus("content")
  end
  return true
end

-- ---------------------------------------------------------------- loading

---@private
function View:_cancel()
  for _, t in pairs(self.tasks) do
    t:cancel()
  end
  self.tasks = {}
end

---@private
function View:_run(name, t, done)
  self.tasks[name] = t
  t:on_done(function(v, err)
    if self.h.closed or self.tasks[name] ~= t then
      return
    end
    self.tasks[name] = nil
    done(v, err)
  end)
end

--- (Re)load the merge request, its diffs, discussions and drafts.
function View:load()
  self:_cancel()
  self.status = "loading"
  local keep = self:_file() and self:_file().path or self.want_path
  self:_run("mr", gg.merge_requests.get(self:_args()), function(mr, err)
    if err then
      return
    end
    mr.project = mr.project or self.mr.project or self.project
    self.mr, self.full = mr, true
    self.viewed_key = viewed.key(self.ctx.host, self.project, self.iid, self:_head())
    self.viewed = viewed.load(self.viewed_key)
    self:render()
  end)
  self:_run("diffs", gg.mr_changes.diffs_all(self:_args(), { limit = self.ctx.cfg.limit }), function(res, err)
    if err then
      self.status, self.err = "error", err.message or tostring(err)
      return self:render()
    end
    self.status, self.err = "ready", nil
    self.list = files_pane.sorted(model.files(res.items or {}))
    self.truncated = res.truncated == true
    self.content, self.expanded = {}, {}
    self.idx = 1
    for _, f in ipairs(self.list) do
      if f.path == keep or f.old_path == keep then
        self.idx = f.index
      end
    end
    self:render()
    self:_first_change()
    self:_sync_side()
  end)
  if not self.me then
    self:_run("me", gg.users.current({ host = self.ctx.host }), function(u)
      self.me = u
      self:render()
    end)
  end
  self:_load_threads()
  self:render()
end

-- the discussions and the drafts; afterwards the cursor goes to the row
-- `follow(info)` accepts
---@private
function View:_load_threads(follow)
  local pending = 2
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    self:render()
    if follow then
      self:_goto(follow)
    end
  end
  self:_run("discussions", gg.notes.discussions_all(self:_args({ noteable = "merge_request" }), { limit = self.ctx.cfg.limit }), function(res, err)
    if err then
      vim.notify("gg.ui: " .. (err.message or tostring(err)), vim.log.levels.ERROR)
    else
      self.discussions = res.items or {}
    end
    done()
  end)
  self:_run("drafts", gg.reviews.drafts_all(self:_args(), { limit = self.ctx.cfg.limit }), function(res, err)
    -- no drafts API (or no right to it): the review is read-only, not broken
    self.drafts = not err and res.items or {}
    done()
  end)
end

---@private
function View:_cache_file(sha, path)
  local dir = vim.fn.stdpath("cache") .. "/gg/files/" .. sha
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. vim.fn.sha256(path)
end

-- the raw content of `path` at `sha`, as lines: from the cache, or fetched
---@private
function View:_raw(project, path, sha, cb)
  local out = self:_cache_file(sha, path)
  local function read()
    local ok, lines = pcall(vim.fn.readfile, out)
    cb(ok and lines or nil, not ok and { message = "cannot read " .. out } or nil)
  end
  if vim.uv.fs_stat(out) then
    return read()
  end
  local name = ("raw:%s:%s"):format(sha, path)
  self:_run(name, gg.files.raw({ host = self.ctx.host, project = project, path = path, ref = sha, output = out }), function(_, err)
    if err then
      return cb(nil, err)
    end
    read()
  end)
end

-- the file's content after the change, for expanded gaps
---@private
function View:_need_content(file)
  local c = self.content[file.path]
  if c then
    return c.status == "ready"
  end
  local sha = self:_head()
  if not (self.full and sha) then
    edit.refuse("The merge request is still loading")
    return false
  end
  self.content[file.path] = { status = "loading" }
  self:_raw(self.mr.source_project_id or self.project, file.new_path, sha, function(lines, err)
    if err then
      self.content[file.path] = nil
      self.expanded[file.path] = nil
      vim.notify("gg.ui: cannot load the file: " .. (err.message or tostring(err)), vim.log.levels.ERROR)
    else
      self.content[file.path] = { status = "ready", lines = lines }
    end
    self:render()
  end)
  return false
end

-- a file GitLab sent without a diff (too large, collapsed): fetch both
-- sides and diff them here
---@private
function View:_load_diff(file)
  local refs = self.mr.diff_refs
  if not (self.full and refs and refs.base_sha and refs.head_sha) then
    return edit.refuse("The merge request is still loading")
  end
  if self.content[file.path] then
    return
  end
  self.content[file.path] = { status = "loading" }
  self:render()
  local old, new
  local left = 2
  local failed
  local function done(err)
    failed = failed or err
    left = left - 1
    if left > 0 then
      return
    end
    self.content[file.path] = nil
    if failed then
      vim.notify("gg.ui: cannot load the file: " .. (failed.message or tostring(failed)), vim.log.levels.ERROR)
      return self:render()
    end
    local a, b = table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n"
    local text = vim.diff(#old > 0 and a or "", #new > 0 and b or "", { result_type = "unified", ctxlen = M.CONTEXT_LINES })
    local f = model.file(file.raw, file.index, gg.diff.parse(text))
    if #f.hunks == 0 then
      f.unavailable = "no text changes"
    end
    self.list[file.index] = f
    if #new > 0 then
      self.content[file.path] = { status = "ready", lines = new }
    end
    self:render()
    self:_first_change()
  end
  if file.status == "A" then
    old = {}
    done()
  else
    self:_raw(self.project, file.old_path, refs.base_sha, function(lines, err)
      old = lines or {}
      done(err)
    end)
  end
  if file.status == "D" then
    new = {}
    done()
  else
    self:_raw(self.mr.source_project_id or self.project, file.new_path, refs.head_sha, function(lines, err)
      new = lines or {}
      done(err)
    end)
  end
end

-- ---------------------------------------------------------------- drawing

---@private
function View:_threads()
  local file = self:_file()
  if not file then
    return {}
  end
  return threads.for_file(file, self.discussions, self.drafts, { me = self.me, folded = self.tstate.folded })
end

---@private
function View:_header()
  local h, mr = self.h, self.mr
  local width = h:header_width()
  local body = header.build({
    width = width,
    pill = mr_render.pill(mr),
    title = mr.title or "",
    ref = "!" .. tostring(mr.iid),
  })
  local meta = {}
  if self.status == "ready" then
    local seen = 0
    for _, f in ipairs(self.list) do
      if self.viewed[f.path] then
        seen = seen + 1
      end
    end
    local c = self.counts
    table.insert(meta, { ("%d/%d viewed"):format(seen, #self.list) })
    table.insert(meta, { (" · %d thread%s"):format(c.threads, c.threads == 1 and "" or "s") })
    if c.pending > 0 then
      table.insert(meta, { (" · %d pending"):format(c.pending), "GitlabBadgePending" })
    end
  end
  local crumb = header.crumb("merge requests") .. "!" .. tostring(mr.iid) .. " › "
  h:set_header(body, header.border_title(width, crumb, "review", meta))
end

---@private
function View:_side()
  local h = self.h
  local f = h.sidebar_float
  if not f then
    return
  end
  h:set_sidebar(files_pane.render({
    width = h:sidebar_width(),
    status = self.status,
    error = self.err,
    files = self.list,
    current = self.idx,
    viewed = self.viewed,
    counts = self.counts.files,
    collapsed = self.collapsed,
  }))
  local k = h.keys
  local open = picker.lhs_list(k.open_item)
  local hints = vim.tbl_filter(function(x)
    return x.key ~= nil
  end, { { key = open[#open], desc = "Open" }, { key = fk(k.comment), desc = "Comment" } })
  float.set_text(f.win, {
    title = { { (" Files %s "):format(self.status == "ready" and #self.list or ""), "GitlabDetailTabActive" } },
    footer = #hints > 0 and hint.chunks(hints) or "",
  })
end

-- the threads pane exists while the files pane does
---@private
function View:_sync_threads_pane()
  local h = self.h
  local g = h.group
  local want = h:has_sidebar() and g._layout().threads ~= nil
  if want and not g.members.threads then
    local f = g:add({
      name = "threads",
      focusable = true,
      filetype = "gg_ui_detail_sidebar",
      win_opts = PANE_WIN_OPTS,
      winhighlight = "CursorLine:GitlabCursorLine",
    })
    self:_threads_maps(f.buf)
    g:relayout()
  elseif not want and g.members.threads then
    g:remove("threads")
    g:relayout()
  end
end

---@private
function View:_threads_maps(buf)
  local k = self.ctx.cfg.keymaps
  local function m(key, fn, desc)
    for _, lhs in ipairs(picker.lhs_list(key)) do
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
  end
  m(k.close, function()
    self.ctx.stack:pop()
  end, "Back")
  m(k.close_all, function()
    self.ctx.stack:close()
  end, "Close")
  m(k.refresh, function()
    self:load()
  end, "Reload")
  m(k.review_focus, function()
    self.h.group:focus("content")
  end, "Diff")
  m(k.submit_review, function()
    self:submit()
  end, "Submit the review")
  m(k.open_item, function()
    self:_threads_open()
  end, "Go to the thread")
end

-- `<CR>` in the threads pane: show the file, the cursor on the thread
---@private
function View:_threads_open()
  local f = self.h.group.members.threads
  if not (f and vim.api.nvim_win_is_valid(f.win)) then
    return
  end
  local d = self.h.docs[f.buf]
  local info = d and d.rows[vim.api.nvim_win_get_cursor(f.win)[1]]
  if not info then
    return
  end
  self:show(info.index)
  self.h.group:focus("content")
  if info.kind == "thread" then
    self:_goto(function(i)
      return i.kind == "comment" and i.thread == info.thread
    end)
  end
end

---@private
function View:_threads_pane()
  self:_sync_threads_pane()
  local f = self.h.group.members.threads
  if not f then
    return
  end
  local groups, count = {}, 0
  if self.status == "ready" then
    groups, count = thread_list.groups(self.list, self.discussions, self.drafts, { me = self.me })
  end
  local d = thread_list.render({ width = vim.api.nvim_win_get_width(f.win), status = self.status, groups = groups })
  local padded = doc.new()
  padded:blank()
  padded:append(d)
  self.h:write(f.buf, padded)
  local open = picker.lhs_list(self.h.keys.open_item)
  float.set_text(f.win, {
    title = { { (" Threads %s "):format(self.status == "ready" and count or ""), "GitlabDetailTabActive" } },
    footer = open[#open] and hint.chunks({ { key = open[#open], desc = "Open" } }) or "",
  })
end

-- the files pane's cursor follows the file shown
---@private
function View:_sync_side()
  local f = self.h.sidebar_float
  if not (f and vim.api.nvim_win_is_valid(f.win)) then
    return
  end
  local d = self.h.docs[f.buf]
  local lnum = d and files_pane.lnum_of(d, self.idx)
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, f.win, { lnum, 0 })
  end
end

-- the keys only a diff box has, its comment hint and its sync, once per
-- buffer: `key` is the host's buffer key, `win()` the box's window
---@private
function View:_box_setup(key, win, name)
  local h, k = self.h, self.h.keys
  local buf = h:buf(key)
  for _, lhs in ipairs(picker.lhs_list(k.comment)) do
    vim.keymap.set("x", lhs, function()
      local a, b = vim.fn.line("v"), vim.fn.line(".")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      self:comment(math.min(a, b), math.max(a, b))
    end, { buffer = buf, nowait = true, silent = true, desc = "Comment on the lines" })
  end
  table.insert(
    self._hints,
    editing.cursor_hint(h, key, function(info, lnum, rows)
      return self:_hint(info, lnum, rows)
    end, {
      win = win,
      -- side by side only the box with the focus
      show = function(w)
        return not self.split or vim.api.nvim_get_current_win() == w
      end,
    })
  )
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = h.augroup,
    buffer = buf,
    callback = function()
      local w = win()
      if w and vim.api.nvim_win_is_valid(w) then
        self:_follow({ name = name, win = w, buf = buf })
      end
    end,
  })
end

---@private
function View:_draw_hints()
  for _, draw in ipairs(self._hints or {}) do
    draw()
  end
end

-- the new side's box exists while side by side
---@private
function View:_sync_split_pane()
  local h = self.h
  local g = h.group
  if self.split and not g.members.right then
    local buf = h:buf("right")
    g:add({
      name = "right",
      focusable = true,
      buf = buf,
      title = " ",
      win_opts = PANE_WIN_OPTS,
      winhighlight = "CursorLine:GitlabCursorLine",
    })
    if not self._right_ready then
      self._right_ready = true
      self:_box_setup("right", function()
        local r = g.members.right
        return r and r.win or nil
      end, "right")
    end
    g:relayout()
  elseif not self.split and g.members.right then
    g:remove("right")
    g:relayout()
  end
end

---@private
function View:_chrome(file)
  local h, k = self.h, self.h.keys
  if not file then
    h:set_title({ { " Changes ", "GitlabDetailTabActive" } })
    h:set_right(nil, nil)
    h:set_hints(M.TAB, {})
    return
  end
  local pending = self.counts.pending
  local pending_label = pending > 0 and { { (" %d pending "):format(pending), "GitlabBadgePending" } } or nil
  local place = { " · %s · %d/%d ", file.status, file.index, #self.list }
  local hints = {
    { key = fk(k.comment), desc = "Comment" },
    { key = fk(k.toggle_viewed), desc = self.viewed[file.path] and "Not viewed" or "Viewed" },
    { key = fk(k.next_file), desc = "Next file" },
    { key = fk(k.submit_review), desc = "Submit" },
    { key = fk(k.toggle_split), desc = self.split and "Unified" or "Side by side" },
  }
  local box = self.split and h.group.members.right
  if box then
    -- the old file left, the new one right; the hints in the box in use
    local on_right = self:_pane().name == "right"
    h:set_title({ { " " .. file.old_path .. " ", "GitlabDetailTabActive" } })
    h:set_right(file.deletions and { { " −" .. file.deletions .. " ", "GitlabDiffDelete" } } or nil, nil)
    h:set_hints(M.TAB, on_right and {} or hints)
    local right = { { " ", "GitlabDetailMuted" } }
    table.insert(right, { file.additions and ("+" .. file.additions) or "±?", file.additions and "GitlabDiffAdd" or "GitlabDetailMuted" })
    table.insert(right, { place[1]:format(place[2], place[3], place[4]), "GitlabDetailMuted" })
    local shown = vim.tbl_filter(function(x)
      return x.key ~= nil
    end, hints)
    h.group:set_labels("right", {
      title = { { " " .. file.new_path .. " ", "GitlabDetailTabActive" } },
      title_right = right,
      footer = on_right and #shown > 0 and hint.chunks(shown) or "",
      footer_right = pending_label or "",
    })
    return
  end
  local name = file.status == "R" and file.old_path ~= file.new_path and (file.old_path .. " → " .. file.new_path) or file.path
  h:set_title({ { " " .. name .. " ", "GitlabDetailTabActive" } })
  local right = { { " ", "GitlabDetailMuted" } }
  if file.additions == nil then
    table.insert(right, { "±?", "GitlabDetailMuted" })
  else
    table.insert(right, { "+" .. file.additions, "GitlabDiffAdd" })
    table.insert(right, { " −" .. file.deletions, "GitlabDiffDelete" })
  end
  table.insert(right, { place[1]:format(place[2], place[3], place[4]), "GitlabDetailMuted" })
  h:set_right(right, pending_label)
  h:set_hints(M.TAB, hints)
end

--- Redraw everything.
function View:render()
  local h = self.h
  if h.closed then
    return
  end
  self.counts = threads.counts(self.list, self.discussions, self.drafts)
  self:_sync_split_pane()
  self:_header()
  self:_side()
  self:_threads_pane()
  local file = self.status == "ready" and self:_file() or nil
  local box = self.split and h.group.members.right or nil
  local d, right
  if file then
    local c = self.content[file.path]
    local rows = model.rows(file, { content = c and c.lines or nil, expanded = self.expanded[file.path] })
    self.file_threads = self:_threads()
    local input = {
      width = h:content_width(),
      width_right = box and self:_width(box.win) or nil,
      status = "ready",
      file = file,
      rows = rows,
      placed = threads.place(rows, self.file_threads),
      state = self.tstate,
      me = self.me and self.me.username or nil,
      utc_offset = date.utc_offset(),
      user_colors = h.cfg.user_colors,
      keys = { fold = fk(h.keys.toggle_fold) },
      fetching = c ~= nil and c.status == "loading",
      truncated = self.truncated,
    }
    if box then
      d, right = render.render_split(input)
    else
      d = render.render(input)
    end
  else
    self.file_threads = {}
    d = render.render({ width = h:content_width(), status = self.status, error = self.err })
    right = box and doc.new() or nil
  end
  if self.status ~= "ready" then
    local padded = doc.new()
    padded:blank()
    padded:append(d)
    d = padded
  end
  local buf = h:buf(M.TAB)
  h:write(buf, d)
  -- side by side each box is one file: the old one, the new one
  self:_syntax(buf, d, file, box ~= nil)
  if box then
    h:write(box.buf, right)
    self:_syntax(box.buf, right, file, true)
    self:_follow(self:_pane())
  end
  self:_chrome(file)
  self:_draw_hints()
end

-- treesitter colours for the code: the new side and the removed lines are
-- parsed as two texts (`whole`: every line as one, a side-by-side box),
-- their captures laid over the buffer lines
---@private
function View:_syntax(buf, d, file, whole)
  vim.api.nvim_buf_clear_namespace(buf, self.syn_ns, 0, -1)
  if not file then
    return
  end
  pcall(function()
    local ft = vim.filetype.match({ filename = file.new_path })
    local lang = ft and vim.treesitter.language.get_lang(ft) or nil
    if not lang then
      return
    end
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
      return
    end
    for _, old_side in ipairs(whole and { "all" } or { false, true }) do
      local text, map = {}, {}
      for lnum = 1, #d.lines do
        local info = d.rows[lnum]
        if info and info.kind == "line" and (old_side == "all" or (info.type == "delete") == old_side) then
          table.insert(text, d.lines[lnum]:sub(info.col + 1))
          table.insert(map, { lnum - 1, info.col })
        end
      end
      if #text > 0 and #text <= M.SYNTAX_MAX_LINES then
        local src = table.concat(text, "\n")
        local tree = vim.treesitter.get_string_parser(src, lang):parse()[1]
        for id, node in query:iter_captures(tree:root(), src, 0, -1) do
          local name = query.captures[id]
          if name:sub(1, 1) ~= "_" and name ~= "spell" and name ~= "nospell" and name ~= "conceal" then
            local sr, sc, er, ec = node:range()
            for r = sr, er do
              local at = map[r + 1]
              local from = r == sr and sc or 0
              local to = r == er and ec or #text[r + 1]
              if at and to > from then
                vim.api.nvim_buf_set_extmark(buf, self.syn_ns, at[1], at[2] + from, {
                  end_col = at[2] + to,
                  hl_group = "@" .. name .. "." .. lang,
                  priority = 90,
                  strict = false,
                })
              end
            end
          end
        end
      end
    end
  end)
end

-- ---------------------------------------------------------------- moving

---@class gg.ui.ReviewPane
---@field name "content"|"right" the group member
---@field win integer
---@field buf integer

-- the boxes of the diff: the content, and side by side the new side's box
---@private
---@return gg.ui.ReviewPane[]
function View:_panes()
  local h = self.h
  local out = { { name = "content", win = h.content_float.win, buf = h:buf(M.TAB) } }
  local r = self.split and h.group.members.right
  if r and vim.api.nvim_win_is_valid(r.win) then
    table.insert(out, { name = "right", win = r.win, buf = r.buf })
  end
  return out
end

-- the diff box with the focus, else the one that had it last
---@private
---@return gg.ui.ReviewPane
function View:_pane()
  local panes = self:_panes()
  local cur = vim.api.nvim_get_current_win()
  for _, p in ipairs(panes) do
    if p.win == cur then
      return p
    end
  end
  for _, p in ipairs(panes) do
    if p.name == self.last_pane then
      return p
    end
  end
  return panes[1]
end

-- the row under the cursor of the diff box in use, its line number and box
---@private
---@return table|nil info
---@return integer|nil lnum
---@return gg.ui.ReviewPane pane
function View:_current()
  local p = self:_pane()
  if not vim.api.nvim_win_is_valid(p.win) then
    return nil, nil, p
  end
  local lnum = vim.api.nvim_win_get_cursor(p.win)[1]
  local d = self.h.docs[p.buf]
  return d and d.rows[lnum] or nil, lnum, p
end

-- the other box's cursor and view follow box `p` (side by side)
---@private
function View:_follow(p)
  if self._following or not self.split then
    return
  end
  for _, o in ipairs(self:_panes()) do
    if o.win ~= p.win and vim.api.nvim_win_is_valid(p.win) then
      self._following = true
      local lnum = vim.api.nvim_win_get_cursor(p.win)[1]
      local top = vim.fn.line("w0", p.win)
      pcall(vim.api.nvim_win_call, o.win, function()
        local v = vim.fn.winsaveview()
        v.lnum, v.topline = lnum, top
        vim.fn.winrestview(v)
      end)
      self._following = false
    end
  end
end

-- the cursor on line `lnum` of box `p`; the focus goes there when the
-- other box had it
---@private
function View:_put(p, lnum, col)
  if not vim.api.nvim_win_is_valid(p.win) then
    return
  end
  local count = vim.api.nvim_buf_line_count(p.buf)
  pcall(vim.api.nvim_win_set_cursor, p.win, { math.max(1, math.min(count, lnum)), col or 0 })
  local cur = vim.api.nvim_get_current_win()
  if cur ~= p.win then
    for _, o in ipairs(self:_panes()) do
      if o.win == cur then
        self.h.group:focus(p.name)
        break
      end
    end
  end
  self.last_pane = p.name
  self:_follow(p)
end

-- a predicate for the row of the same diff line as `info`
local function same_line(info)
  return function(i)
    return i.kind == "line" and i.type == info.type and i.old_line == info.old_line and i.new_line == info.new_line
  end
end

--- `<Tab>` side by side: the focus to the other box, the cursor on the same
--- line (on the text when the line has some there).
function View:switch_side()
  local _, lnum, from = self:_current()
  for _, p in ipairs(self:_panes()) do
    if p.name ~= from.name then
      local d = self.h.docs[p.buf]
      local info = d and lnum and d.rows[lnum]
      self.h.group:focus(p.name)
      self:_put(p, lnum or 1, info and info.kind == "line" and info.col or 0)
      return
    end
  end
end

--- `gV`: side by side, the old file and the new one in two boxes (the files
--- and threads panes hidden for the room), or unified again; the cursor
--- stays on its line of the diff.
function View:toggle_split()
  local h = self.h
  local info = self:_current()
  -- the right box is about to close: the focus must not be in it
  h.group:focus("content")
  self.split = not self.split
  self.last_pane = nil
  h:want_sidebar_shown(not self.split)
  self:render()
  if info and info.kind == "line" then
    self:_goto(same_line(info))
  elseif info and (info.note or info.index) then
    self:_goto(function(i)
      if info.note then
        return i.note == info.note
      end
      return i.kind == info.kind and i.index == info.index
    end)
  end
end

-- the cursor to the first row `pred(info)` accepts (side by side: in
-- either box, the one in use first)
---@private
function View:_goto(pred)
  local first = self:_pane()
  local panes = { first }
  for _, p in ipairs(self:_panes()) do
    if p.name ~= first.name then
      table.insert(panes, p)
    end
  end
  local n = 0
  for _, p in ipairs(panes) do
    local d = self.h.docs[p.buf]
    n = math.max(n, d and #d.lines or 0)
  end
  for lnum = 1, n do
    for _, p in ipairs(panes) do
      local d = self.h.docs[p.buf]
      local info = d and d.rows[lnum]
      if info and pred(info) then
        self:_put(p, lnum)
        return true
      end
    end
  end
  return false
end

---@private
function View:_first_change()
  if not self:_goto(function(info)
    return info.kind == "line" and info.type ~= "context"
  end) then
    self:_put(self:_pane(), 1)
  end
end

--- Show file `index`.
---@param index integer
---@param opts? { keep_side?: boolean } leave the files pane's cursor alone
function View:show(index, opts)
  if not self.list[index] then
    return
  end
  self.idx = index
  self:render()
  self:_first_change()
  if not (opts and opts.keep_side) then
    self:_sync_side()
  end
end

--- The next (1) or previous (-1) file, wrapping around.
---@param dir integer
function View:step_file(dir)
  local n = #self.list
  if n > 0 then
    self:show((self.idx - 1 + dir) % n + 1)
  end
end

--- Choose a file from a list.
function View:pick_file()
  if #self.list == 0 then
    return
  end
  confirm.select(self.list, {
    prompt = "Files",
    format_item = function(f)
      return ("%s%s"):format(self.viewed[f.path] and "✓ " or "  ", f.path)
    end,
  }, function(f)
    if f then
      self:show(f.index)
      self.h.group:focus("content")
    end
  end)
end

--- Jump to the next / previous hunk (a run of changed lines) or thread.
---@param what "hunk"|"thread"
---@param dir integer 1 or -1
function View:jump(what, dir)
  local h = self.h
  local _, cur, first = self:_current()
  if not cur then
    return
  end
  -- side by side the boxes are searched together, the one in use first
  local panes = { first }
  for _, p in ipairs(self:_panes()) do
    if p.name ~= first.name then
      table.insert(panes, p)
    end
  end
  local function starts(d, lnum)
    local info, prev = d.rows[lnum], d.rows[lnum - 1]
    if not info then
      return false
    end
    if what == "hunk" then
      -- threads (and the other side's filler) between the lines of a
      -- change do not split it
      local at = lnum - 1
      while prev and (prev.thread or prev.kind == "filler") do
        at = at - 1
        prev = d.rows[at]
      end
      return info.kind == "line" and info.type ~= "context" and not (prev and prev.kind == "line" and prev.type ~= "context")
    end
    return info.kind == "comment" and not (prev and prev.thread == info.thread)
  end
  local d0 = h.docs[first.buf]
  local n = d0 and #d0.lines or 0
  for step = 1, n do
    local lnum = (cur - 1 + dir * step) % n + 1
    for _, p in ipairs(panes) do
      local d = h.docs[p.buf]
      if d and starts(d, lnum) then
        return self:_put(p, lnum)
      end
    end
  end
end

--- `za` / `<CR>`: expand the gap under the cursor (or fold it again from
--- one of its lines), load a diff that was not sent; on a thread, fold its
--- replies or show a long comment in full.
function View:toggle_fold()
  local info = self:_current()
  local file = self:_file()
  if not (info and file) then
    return
  end
  if info.kind == "unavailable" then
    if info.loadable then
      self:_load_diff(file)
    end
    return
  end
  if info.kind == "fold" or (info.kind == "line" and info.gap) then
    local e = self.expanded[file.path] or {}
    self.expanded[file.path] = e
    local gap = info.gap
    if info.kind == "line" then
      e[gap] = nil
      self:render()
      self:_goto(function(i)
        return i.kind == "fold" and i.gap == gap
      end)
      return
    end
    e[gap] = true
    self:_need_content(file)
    self:render()
    return
  end
  if not info.thread then
    return
  end
  local st = self.tstate
  if info.kind == "comment" and info.long then
    st.expanded_notes[info.note] = not st.expanded_notes[info.note] or nil
  else
    st.folded[info.thread] = not st.folded[info.thread] or nil
  end
  local note, thread = info.note, info.thread
  self:render()
  if not self:_goto(function(i)
    return i.note == note and i.thread == thread
  end) then
    self:_goto(function(i)
      return i.thread == thread
    end)
  end
end

--- `zA`: show the whole file, or collapse the unchanged lines again.
function View:toggle_all()
  local file = self:_file()
  if not file or file.unavailable then
    return
  end
  local info = self:_current()
  if next(self.expanded[file.path] or {}) then
    self.expanded[file.path] = nil
  else
    self.expanded[file.path] = model.all_gaps(file)
    self:_need_content(file)
  end
  self:render()
  if info and info.kind == "line" then
    self:_goto(same_line(info))
  end
end

--- `x`: mark the file viewed (and go to the next one not viewed) or not.
function View:toggle_viewed()
  local file = self:_file()
  if not file then
    return
  end
  local on = not self.viewed[file.path]
  self.viewed[file.path] = on or nil
  if self.viewed_key then
    viewed.save(self.viewed_key, self.viewed)
  end
  if on then
    local n = #self.list
    for step = 1, n - 1 do
      local f = self.list[(self.idx - 1 + step) % n + 1]
      if not self.viewed[f.path] then
        return self:show(f.index)
      end
    end
  end
  self:render()
end

-- ---------------------------------------------------------------- comments

-- the thread and the note behind a row
---@private
function View:_find(info)
  for _, t in ipairs(self.file_threads or {}) do
    if t.id == info.thread then
      if t.root.id == info.note then
        return t, t.root
      end
      for _, n in ipairs(t.replies) do
        if n.id == info.note then
          return t, n
        end
      end
      return t, nil
    end
  end
end

---@private
function View:_mine(note)
  return note.pending or (self.me and note.author and note.author.username == self.me.username)
end

-- "[gc] reply · [gE] edit · [gD] delete · [gX] resolve · [za] expand" in
-- the bottom border of the comment under the cursor
---@private
---@param info table
---@param lnum integer
---@param rows table<integer, table>
function View:_hint(info, lnum, rows)
  if info.kind ~= "comment" then
    return nil
  end
  local t, note = self:_find(info)
  if not t then
    return nil
  end
  local k = self.h.keys
  local parts = {}
  if not t.pending then
    table.insert(parts, { fk(k.reply), "reply" })
  end
  if note and self:_mine(note) then
    table.insert(parts, { fk(k.edit_comment), "edit" })
    table.insert(parts, { fk(k.delete_comment), "delete" })
  end
  if t.resolvable then
    table.insert(parts, { fk(k.toggle_resolved), t.resolved and "unresolve" or "resolve" })
  end
  return activity_render.comment_hint(info, lnum, rows, parts, fk(k.toggle_fold))
end

-- a position with the diff refs the diff was loaded with
---@private
function View:_with_refs(pos)
  local refs = self.mr.diff_refs
  if refs and refs.base_sha and refs.head_sha and refs.start_sha then
    pos.base_sha, pos.head_sha, pos.start_sha = refs.base_sha, refs.head_sha, refs.start_sha
  end
  return pos
end

-- after a change: reload the threads, tell the screens below
---@private
function View:_changed(follow)
  self:_load_threads(follow)
  self.ctx.stack:changed("merge_request")
end

---@private
function View:_compose(o)
  return editing.compose(self.h, vim.tbl_extend("force", {
    col = 2,
    width = math.floor(self:_width(o.win) * 0.9) - 2,
    mentions = function()
      return edits.mentions(self.mr, self.discussions)
    end,
    render = function()
      self:render()
    end,
  }, o))
end

-- the inner width of diff box `win` (default: the content)
---@private
function View:_width(win)
  if win and vim.api.nvim_win_is_valid(win) then
    return vim.api.nvim_win_get_width(win)
  end
  return self.h:content_width()
end

-- a new comment at `pos`, added to the review or posted at once; `place`
-- is in box `win`
---@private
function View:_new_comment(pos, label, place, win)
  pos = self:_with_refs(pos)
  return self:_compose({
    win = win,
    what = "comment",
    busy = "Adding the comment to the review…",
    success = "Comment added to the review",
    title = "Comment · " .. label,
    placeholder = "write a comment · markdown, @ to mention",
    place = place,
    labels = { submit = "Add to review" },
    alt = { key = self.h.keys.post_now, desc = "Post now", busy = "Posting the comment…", success = "Comment posted" },
    post = function(text, _, alt)
      if alt then
        return gg.notes.add(self:_args({ noteable = "merge_request", body = text, position = pos }))
      end
      return gg.reviews.create_draft(self:_args({ note = text, position = pos }))
    end,
    apply = function(res, alt)
      local id = alt and res and res.notes and res.notes[1] and res.notes[1].id or (res and res.id and ("draft:" .. tostring(res.id)))
      self:_changed(function(i)
        return i.note == id
      end)
    end,
  })
end

--- `i`: comment on the line under the cursor, or on lines `first` to
--- `last` (buffer lines) of a visual selection. On a thread it replies.
---@param first? integer
---@param last? integer
function View:comment(first, last)
  local h = self.h
  local file = self:_file()
  if not file then
    return
  end
  local info, lnum, pane = self:_current()
  local d = h.docs[pane.buf]
  if not first then
    if info and info.thread then
      return self:reply()
    end
    first, last = lnum, lnum
  end
  local pos, why = position.lines(file, d and d.rows[first], d and d.rows[last])
  if not pos then
    local key = fk(h.keys.comment)
    return edit.refuse(why .. (key and (" ([" .. key .. "] in the files pane comments on the whole file)") or ""))
  end
  return self:_new_comment(pos, position.label(file, pos), { bufpos = last - 1 }, pane.win)
end

--- Comment on the whole file shown.
function View:comment_file()
  local file = self:_file()
  if not file then
    return
  end
  local pos = position.file(file)
  -- side by side, comments on the file are in the new side's box
  local panes = self:_panes()
  return self:_new_comment(pos, position.label(file, pos), { bufpos = 0 }, panes[#panes].win)
end

-- the last row of thread `id` (0-based) and the box it is in
---@private
---@return integer|nil
---@return gg.ui.ReviewPane|nil
function View:_thread_end(id)
  for _, p in ipairs(self:_panes()) do
    local d = self.h.docs[p.buf]
    local last
    for lnum = 1, d and #d.lines or 0 do
      local info = d.rows[lnum]
      if info and info.thread == id and info.kind ~= "gap" then
        last = lnum
      end
    end
    if last then
      return last - 1, p
    end
  end
  return nil, nil
end

--- `gc`: reply to the thread under the cursor; the reply joins the review,
--- `post_now` sends it at once.
function View:reply()
  local info = self:_current()
  if not (info and info.thread) then
    return
  end
  local t, note = self:_find(info)
  if not t then
    return
  end
  if t.pending then
    return edit.refuse("A pending comment has no replies yet: edit it instead")
  end
  local seed = ""
  local who = note and not note.pending and note.author and note.author.username
  if who and not (self.me and who == self.me.username) then
    seed = "@" .. who .. " "
  end
  local after, pane = self:_thread_end(t.id)
  return self:_compose({
    win = pane and pane.win or nil,
    what = "reply",
    busy = "Adding the reply to the review…",
    success = "Reply added to the review",
    title = "↩ Reply to thread",
    placeholder = "write a reply · markdown, @ to mention",
    text = seed,
    place = after and { bufpos = after } or nil,
    col = 6,
    width = math.floor(self:_width(pane and pane.win) * 0.9) - 6,
    resolve = t.resolvable and not t.resolved,
    labels = { submit = "Add to review", resolve = "Add & resolve" },
    alt = { key = self.h.keys.post_now, desc = "Post now", busy = "Sending the reply…", success = "Reply added" },
    post = function(text, resolve, alt)
      if alt then
        return gg.notes.reply(self:_args({ noteable = "merge_request", discussion_id = t.id, body = text }))
      end
      return gg.reviews.create_draft(self:_args({ note = text, in_reply_to_discussion_id = t.id, resolve_discussion = resolve or nil }))
    end,
    apply = function(res, alt)
      local id = res and res.id and (alt and res.id or ("draft:" .. tostring(res.id)))
      self:_changed(function(i)
        return i.note == id
      end)
    end,
  })
end

-- the comment under the cursor when it is yours
---@private
function View:_own()
  local info = self:_current()
  if not (info and info.kind == "comment") then
    return nil
  end
  local t, note = self:_find(info)
  if not note then
    return nil
  end
  if not self:_mine(note) then
    edit.refuse("Only your own comments can be changed")
    return nil
  end
  return note, t
end

--- `gE`: edit your comment (published or pending) under the cursor.
function View:edit_comment()
  local note, t = self:_own()
  if not note then
    return
  end
  local head, win
  for _, p in ipairs(self:_panes()) do
    local d = self.h.docs[p.buf]
    for lnum = 1, d and #d.lines or 0 do
      local info = d.rows[lnum]
      if info and info.note == note.id and info.thread == t.id then
        head, win = lnum - 1, p.win
        break
      end
    end
    if head then
      break
    end
  end
  return self:_compose({
    win = win,
    what = "comment",
    busy = "Editing the comment…",
    success = "Comment updated",
    title = note.pending and "✎ Edit pending comment" or "✎ Edit comment",
    text = note.body or "",
    place = head and { bufpos = head } or nil,
    post = function(text)
      if note.pending then
        return gg.reviews.edit_draft(self:_args({ draft_id = note.draft_id, note = text }))
      end
      return gg.notes.edit(self:_args({ noteable = "merge_request", note_id = note.id, discussion_id = t.id, body = text }))
    end,
    apply = function()
      self:_changed(function(i)
        return i.note == note.id
      end)
    end,
  })
end

--- `gD`: delete your comment (published or pending) under the cursor.
function View:delete_comment()
  local note, t = self:_own()
  if not note then
    return
  end
  confirm.ask(note.pending and "Delete pending comment?" or "Delete comment?", function()
    edit.run({
      what = "comment",
      busy = "Deleting the comment…",
      success = "Comment deleted",
      task = function()
        if note.pending then
          return gg.reviews.delete_draft(self:_args({ draft_id = note.draft_id }))
        end
        return gg.notes.delete(self:_args({ noteable = "merge_request", note_id = note.id, discussion_id = t.id }))
      end,
      alive = function()
        return not self.h.closed
      end,
      apply = function()
        self:_changed(nil)
      end,
    })
  end)
end

--- `gX`: resolve or unresolve the thread under the cursor (at once).
function View:toggle_resolved()
  local info = self:_current()
  if not (info and info.thread) then
    return
  end
  local t = self:_find(info)
  if not t then
    return
  end
  if not t.resolvable then
    return edit.refuse("This thread cannot be resolved")
  end
  local resolve = not t.resolved
  edit.run({
    what = "thread",
    busy = resolve and "Resolving the thread…" or "Reopening the thread…",
    success = resolve and "Thread resolved" or "Thread reopened",
    task = function()
      return gg.notes.set_resolved(self:_args({ noteable = "merge_request", discussion_id = t.id, resolved = resolve }))
    end,
    alive = function()
      return not self.h.closed
    end,
    apply = function()
      self:_changed(function(i)
        return i.thread == t.id
      end)
    end,
  })
end

-- ---------------------------------------------------------------- submit

--- `gs`: submit the review: choose what it is (comment, approve, request
--- changes), write an optional summary, send. Also lists or discards the
--- pending comments.
function View:submit()
  if self.h.editing then
    return edit.refuse("Finish the current edit first")
  end
  local pending = #(self.drafts or {})
  confirm.select(submit.actions(pending), {
    prompt = submit.title(pending),
    format_item = function(a)
      return a.label
    end,
  }, function(action)
    if not action or self.h.closed then
      return
    end
    if action.key == "show" then
      return self:_show_pending()
    elseif action.key == "discard" then
      return confirm.ask(("Discard %d pending comment%s?"):format(pending, pending == 1 and "" or "s"), function()
        edit.run({
          what = "review",
          busy = "Discarding the pending comments…",
          success = "Pending comments discarded",
          task = function()
            return gg.reviews.discard_drafts(self:_args(), { limit = self.ctx.cfg.limit })
          end,
          alive = function()
            return not self.h.closed
          end,
          apply = function()
            self:_changed(nil)
          end,
          rollback = function()
            self:_load_threads()
          end,
        })
      end)
    end
    self:_send(action)
  end)
end

-- choose a pending comment and go to it
---@private
function View:_show_pending()
  local entries = submit.pending(self.drafts, self.discussions)
  confirm.select(entries, {
    prompt = "Pending comments",
    format_item = function(e)
      return e.text
    end,
  }, function(e)
    if not e or self.h.closed then
      return
    end
    if not e.path then
      return edit.refuse("This pending comment is not on a file")
    end
    for _, f in ipairs(self.list) do
      if f.new_path == e.path or f.old_path == e.path then
        self:show(f.index)
        self.h.group:focus("content")
        self:_goto(function(i)
          return i.note == e.note
        end)
        return
      end
    end
  end)
end

-- the summary, then the requests
---@private
function View:_send(action)
  local head = self:_head()
  self.h.group:focus("content")
  return self:_compose({
    what = "review",
    busy = "Submitting the review…",
    success = action.approve and "Review submitted and approved" or "Review submitted",
    title = "Review summary · optional",
    placeholder = "an overall comment · leave empty for none",
    place = { bottom = true },
    col = 0,
    width = self.h:content_width(),
    allow_empty = true,
    labels = { submit = action.verb },
    post = function(text)
      return gg.task.run(function()
        -- new commits since the diff was loaded: the review would be on old code
        local version = gg.mr_changes.latest_version(self:_args()):await()
        if version and head and version.head_commit_sha ~= head then
          return nil, gg.errors.new("validation", "the merge request has new commits: reload and look at them first")
        end
        local _, err = gg.reviews.publish(self:_args({
          note = text ~= "" and text or nil,
          reviewer_state = action.reviewer_state,
        })):await()
        if err then
          return nil, err
        end
        if action.approve then
          local _, aerr = gg.reviews.approve(self:_args({ sha = head })):await()
          if aerr then
            return nil, aerr
          end
        end
        return true
      end)
    end,
    apply = function()
      self:_changed(nil)
    end,
  })
end

return M
