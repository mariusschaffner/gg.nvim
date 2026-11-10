--- The merge request detail view: header with the readiness strip,
--- Description, Activity, Changes, Commits and Pipelines tabs, sidebar.
---
--- Opens at once with what the caller already has, then loads the merge
--- request, its merge checks, reviewers, changes and commits in parallel.
--- The Activity and Pipelines tabs load when first shown; the Pipelines tab
--- is the pipelines table (`gg.ui.pipelines.view`) filtered to this merge
--- request, live while it is visible. Edits: `i` the description, `x` a
--- task, `gt` the title, `ga` / `gr` assignees / reviewers, `gl` labels, `gM`
--- milestone, `gB` target branch, `gb` delete the source branch on merge, `A`
--- approve / merge / draft / close.
local activity = require("gg.ui.detail.activity.view")
local confirm = require("gg.ui.components.confirm")
local edit = require("gg.ui.detail.edit")
local editing = require("gg.ui.detail.editing")
local edits = require("gg.ui.detail.edits")
local fields = require("gg.ui.detail.fields")
local changes = require("gg.ui.detail.merge_request.changes")
local closing_refs = require("gg.ui.detail.merge_request.closing_refs")
local commits = require("gg.ui.detail.merge_request.commits")
local date = require("gg.ui.lib.date")
local doc = require("gg.ui.lib.doc")
local gg = require("gg")
local highlights = require("gg.ui.highlights")
local host = require("gg.ui.detail.host")
local list_buffer = require("gg.ui.components.list_buffer")
local picker = require("gg.ui.components.picker")
local pipelines = require("gg.ui.pipelines.view")
local render = require("gg.ui.detail.merge_request.render")

local M = {}

local function loadable(v, err, map)
  if err then
    return { status = "error", error = err.message or tostring(err) }
  end
  return { status = "ready", value = map and map(v) or v }
end

M.TABS = {
  { key = "description", label = "Description" },
  { key = "activity", label = "Activity" },
  { key = "changes", label = "Changes" },
  { key = "commits", label = "Commits" },
  { key = "pipelines", label = "Pipelines" },
}

---@class gg.ui.MrDetail
---@field ctx gg.ui.DetailCtx
---@field h gg.ui.DetailHost
---@field screen gg.ui.Screen
---@field project string
---@field iid integer
---@field mr gg.MergeRequest
---@field full boolean
---@field checks gg.ui.Loadable
---@field reviewers gg.ui.Loadable
---@field stats gg.ui.Loadable
---@field commits gg.ui.Loadable
---@field refs gg.ui.ClosingRef[]
---@field issues table<string, gg.Issue|false>
---@field pipelines gg.ui.PipelinesView
local View = {}
View.__index = View

--- Open the merge request detail view (called through
--- `gg.ui.detail.merge_request`).
---@param ctx gg.ui.DetailCtx
---@param item gg.MergeRequest|{ iid: integer, project?: string }
---@return gg.ui.MrDetail
function M.open(ctx, item)
  highlights.setup()
  local self = setmetatable({
    ctx = ctx,
    project = item.project or ctx.project,
    iid = item.iid,
    mr = vim.deepcopy(item),
    full = false,
    tasks = {},
    refs = {},
    issues = {},
  }, View)
  self.mr.labels = self.mr.labels or {}
  self.mr.assignees = self.mr.assignees or {}
  self.h = host.new({
    stack = ctx.stack,
    cfg = ctx.cfg,
    name = "merge_request",
    sidebar = true,
    tabs = vim.deepcopy(M.TABS),
    on_render = function()
      self:render()
    end,
    on_refresh = function()
      self:load()
    end,
    on_tab = function(key)
      self:_on_tab(key)
    end,
  })
  self.screen = self.h.screen
  self.screen.suspend = function()
    self.pipelines:suspend()
  end
  self.screen.resume = function()
    if self.h.active == "pipelines" then
      self.pipelines:resume()
    end
  end
  self.screen.teardown = function()
    self:_cancel()
    self.activity:cancel()
    self.pipelines:teardown()
  end
  self.activity = activity.new(self.h, {
    tab = "activity",
    noteable = "merge_request",
    host = ctx.host,
    project = self.project,
    iid = self.iid,
    today = ctx.today,
    can_comment = function()
      return self:_open()
    end,
    item = function()
      return self.mr
    end,
    changed = function()
      self.ctx.stack:changed("merge_request")
    end,
  })
  self:_mount_pipelines()
  local k = self.h.keys
  self.h:map_all(k.goto_pipeline, function()
    self:goto_pipeline()
  end, "Pipeline")
  self.h:map("description", k.open_item, function()
    self:open_card()
  end, "Open issue")
  self.sources = fields.sources(ctx.host, self.project)
  -- after open_item: in the description `i` edits, `<CR>` opens a card
  self:_edit_keys()
  -- a file's diff comes with the review view; until then the key says so
  self.file_hint = self.h:map_later("changes", "open_item", "File", "opening a file")
  self:load()
  return self
end

-- the keys that change the merge request
---@private
function View:_edit_keys()
  local h, k = self.h, self.h.keys
  h:map("description", k.edit, function()
    self:edit_description()
  end, "Edit the description")
  h:map("description", k.toggle_task, function()
    self:toggle_task()
  end, "Toggle the task")
  editing.cursor_hint(h, "description", function(info)
    if info.kind == "task" and self:_open() and picker.first_key(k.toggle_task) then
      return { { "[" .. picker.first_key(k.toggle_task) .. "]", "GitlabHintKey" }, { " toggle", "GitlabHintText" } }
    end
  end)
  for _, m in ipairs({
    { k.edit_title, "title" },
    { k.edit_assignees, "assignees" },
    { k.edit_reviewers, "reviewers" },
    { k.edit_labels, "labels" },
    { k.edit_milestone, "milestone" },
    { k.edit_target_branch, "target_branch" },
  }) do
    h:map_all(m[1], function()
      self:edit_field(m[2])
    end, "Edit " .. m[2])
  end
  h:map_all(k.toggle_delete_branch, function()
    self:toggle_delete_branch()
  end, "Toggle deleting the source branch")
  h:map_all(k.actions, function()
    self:actions()
  end, "Actions")
end

---@private
function View:_open()
  return self.mr.state == "opened" or self.mr.state == "locked"
end

---@private
function View:_not_open()
  return edit.refuse("The merge request is " .. tostring(self.mr.state))
end

---@private
function View:_changed()
  self.ctx.stack:changed("merge_request")
  -- the change shows up as an event in the activity
  if self.activity.status ~= "idle" then
    self.activity:load()
  end
end

---@private
function View:_update(fields_)
  return gg.merge_requests.update(vim.tbl_extend("force", self:_args(), fields_))
end

-- take an updated merge request into the view
---@private
function View:_take(mr)
  mr.project = mr.project or self.mr.project or self.project
  local old_desc = self.mr.description
  self.mr = mr
  self.full = true
  if mr.description ~= old_desc then
    self.refs = closing_refs.parse(mr.description)
    self:_load_issues()
  end
end

---@private
function View:_base()
  return {
    h = self.h,
    changed = function()
      self:_changed()
    end,
    render = function()
      self:render()
    end,
    apply = function(mr)
      self:_take(mr)
    end,
  }
end

--- `i`: edit the description in place (fetched again first).
function View:edit_description()
  if not self:_open() then
    return self:_not_open()
  end
  local info = self.h:current()
  editing.text(self.h, vim.tbl_extend("force", self:_base(), {
    what = "description",
    cursor = info and info.src,
    load = function(cb)
      gg.merge_requests.get(self:_args()):on_done(function(mr, err)
        cb(mr and mr.description or nil, err)
      end)
    end,
    save = function(text)
      return self:_update({ description = text })
    end,
  }))
end

--- `x`: toggle the task under the cursor (shown at once, undone on error).
function View:toggle_task()
  local info = self.h:current()
  if not (info and info.kind == "task" and info.src) then
    return
  end
  if not self:_open() then
    return self:_not_open()
  end
  local old = self.mr.description or ""
  local new = edits.toggle_task(old, info.src)
  if not new then
    return
  end
  self.mr.description = new
  self:render()
  edit.run(vim.tbl_extend("force", self:_base(), {
    what = "task",
    task = function()
      return self:_update({ description = new })
    end,
    rollback = function()
      self.mr.description = old
    end,
    alive = function()
      return not self.h.closed
    end,
  }))
end

-- the requested reviewers (not approvers who were not asked)
---@private
function View:_reviewer_users()
  if self.reviewers.status ~= "ready" then
    return self.mr.reviewers or {}
  end
  local users = {}
  for _, r in ipairs(self.reviewers.value) do
    if r.role ~= "participant" then
      table.insert(users, r.user)
    end
  end
  return users
end

--- Edit "title", "assignees", "reviewers", "labels", "milestone" or
--- "target_branch".
---@param name string
function View:edit_field(name)
  if not self.full then
    return edit.refuse("Still loading the merge request")
  end
  if name ~= "labels" and name ~= "milestone" and not self:_open() then
    return self:_not_open()
  end
  local function with(extra)
    return vim.tbl_extend("force", self:_base(), extra)
  end
  if name == "title" then
    fields.title(with({
      text = self.mr.title or "",
      save = function(t)
        return self:_update({ title = t })
      end,
    }))
  elseif name == "assignees" or name == "reviewers" then
    fields.people(with({
      what = name,
      id = name,
      users = name == "assignees" and self.mr.assignees or self:_reviewer_users(),
      source = self.sources.members,
      save = function(ids)
        return self:_update(name == "assignees" and { assignee_ids = ids } or { reviewer_ids = ids })
      end,
      apply = function(mr)
        self:_take(mr)
        if name == "reviewers" then
          self:_reload_reviews()
        end
      end,
    }))
  elseif name == "labels" then
    fields.labels(with({
      labels = self.mr.labels,
      source = self.sources.labels,
      save = function(p)
        return self:_update({ add_labels = p.add, remove_labels = p.remove })
      end,
    }))
  elseif name == "milestone" then
    fields.milestone(with({
      milestone = self.mr.milestone,
      source = self.sources.milestones,
      save = function(id)
        return self:_update({ milestone_id = id })
      end,
    }))
  elseif name == "target_branch" then
    fields.target_branch(with({
      branch = self.mr.target_branch,
      host = self.ctx.host,
      project = self.project,
      save = function(b)
        return self:_update({ target_branch = b })
      end,
      apply = function(mr)
        self:_take(mr)
        self:_reload_reviews()
      end,
    }))
  end
end

-- reviewers and merge checks again (after reviewers, approvals, merges)
---@private
function View:_reload_reviews()
  self:_run("checks", gg.mr_checks.get(self:_args()), function(v, err)
    self.checks = loadable(v, err)
  end)
  self:_run("reviewers", gg.reviews.reviewers(self:_args()), function(v, err)
    self.reviewers = loadable(v, err, function(res)
      return res.reviewers or {}
    end)
  end)
end

--- `gb`: toggle deleting the source branch when merging.
function View:toggle_delete_branch()
  if not self.full then
    return edit.refuse("Still loading the merge request")
  end
  if not self:_open() then
    return self:_not_open()
  end
  local on = not (self.mr.force_remove_source_branch or self.mr.should_remove_source_branch)
  edit.run(vim.tbl_extend("force", self:_base(), {
    what = "delete source branch",
    success = on and "The source branch will be deleted on merge" or "The source branch will be kept",
    task = function()
      return self:_update({ remove_source_branch = on })
    end,
    alive = function()
      return not self.h.closed
    end,
  }))
end

-- did the signed-in user approve?
---@private
function View:_approved_by_me()
  local me = self.me or self.activity.me
  for _, r in ipairs(self.reviewers.status == "ready" and self.reviewers.value or {}) do
    if r.approved and r.user and r.user.username == me then
      return true
    end
  end
  return false
end

---@private
function View:_action(what, busy, success, task, after)
  edit.run(vim.tbl_extend("force", self:_base(), {
    what = what,
    busy = busy,
    success = success,
    task = task,
    apply = function(res)
      if after then
        after(res)
      end
    end,
    alive = function()
      return not self.h.closed
    end,
  }))
end

-- the merge options: config first, else the merge request's own
---@private
function View:_merge_options()
  local cfg, mr = self.ctx.cfg, self.mr
  local squash = cfg.merge_squash
  if squash == nil then
    squash = mr.squash == true
  end
  local delete = cfg.merge_delete_source_branch
  if delete == nil then
    delete = (mr.force_remove_source_branch or mr.should_remove_source_branch) == true
  end
  return squash, delete
end

--- `A`: approve / revoke the approval, merge, ready / draft, close / reopen.
function View:actions()
  if not self.full then
    return edit.refuse("Still loading the merge request")
  end
  local mr = self.mr
  local avail = edits.actions("merge_request", vim.tbl_extend("force", {}, mr, { approved_by_me = self:_approved_by_me() }))
  local ref = "!" .. tostring(mr.iid)
  local function take(m)
    self:_take(m)
    self:_reload_reviews()
  end
  local items = {}
  for _, a in ipairs(avail.actions) do
    if a == "approve" then
      table.insert(items, { label = "Approve", run = function()
        self:_action("approval", "Approving…", "Approved", function()
          return gg.reviews.approve(self:_args())
        end, function()
          self:_reload_reviews()
        end)
      end })
    elseif a == "unapprove" then
      table.insert(items, { label = "Revoke approval", run = function()
        self:_action("approval", "Revoking the approval…", "Approval revoked", function()
          return gg.reviews.unapprove(self:_args())
        end, function()
          self:_reload_reviews()
        end)
      end })
    elseif a == "merge" then
      local squash, delete = self:_merge_options()
      table.insert(items, {
        label = ("Merge%s%s"):format(squash and " (squash)" or "", delete and ", delete the source branch" or ""),
        confirm = ("Merge %s into %s?"):format(ref, mr.target_branch or "the target branch"),
        run = function()
          self:_action("merge", "Merging…", "Merged", function()
            return gg.merge_requests.merge(vim.tbl_extend("force", self:_args(), {
              squash = squash,
              should_remove_source_branch = delete,
            }))
          end, take)
        end,
      })
    elseif a == "ready" or a == "draft" then
      local draft = a == "draft"
      table.insert(items, { label = draft and "Mark as draft" or "Mark as ready", run = function()
        self:_action("draft", draft and "Marking as draft…" or "Marking as ready…", draft and "Marked as draft" or "Marked as ready", function()
          return self:_update({ draft = draft })
        end, take)
      end })
    elseif a == "close" then
      table.insert(items, { label = "Close", confirm = ("Close %s?"):format(ref), run = function()
        self:_action("state", "Closing…", "Closed", function()
          return self:_update({ state_event = "close" })
        end, take)
      end })
    elseif a == "reopen" then
      table.insert(items, { label = "Reopen", run = function()
        self:_action("state", "Reopening…", "Reopened", function()
          return self:_update({ state_event = "reopen" })
        end, take)
      end })
    end
  end
  confirm.menu("Merge request " .. ref, items)
end

-- the pipelines table in the Pipelines tab
---@private
function View:_mount_pipelines()
  local h = self.h
  local tab = "pipelines"
  local ctrl
  local list = list_buffer.new({
    buf = h:buf(tab),
    win = h.content_float.win,
    on_select = function(lnum)
      if ctrl and h.active == tab then
        ctrl:on_select(lnum)
      end
    end,
    cursor_col = function(lnum)
      local r = ctrl and ctrl.rendered
      local row = r and r.rows[lnum]
      return row and row.mark_col or 0
    end,
  })
  list:attach_navigation()
  ctrl = pipelines.mount({
    cfg = self.ctx.cfg,
    host = self.ctx.host,
    project = self.project,
    mr_iid = self.iid,
    no_tabs = true, -- one table of every pipeline of the merge request
    surface = {
      list = list,
      active = function()
        return h:visible() and h.active == tab
      end,
      width = function()
        return h:content_width()
      end,
      chrome = function()
        self:_tabs()
      end,
      overlay = function() end,
      open = function(p)
        require("gg.ui.detail").pipeline(self:_ctx(), p)
      end,
      close = function()
        h:close()
      end,
    },
  })
  self.pipelines = ctrl
  local k = h.keys
  h:map(tab, k.open_item, function()
    ctrl:inspect()
  end, "Open pipeline")
  h:map(tab, k.next_page, function()
    ctrl:next_page()
  end, "Load more")
  h:set_hints(tab, { { key = picker.first_key(k.open_item), desc = "Pipeline" } })
end

---@private
function View:_on_tab(key)
  if key == "activity" and self.activity.status == "idle" then
    self.activity:load()
  elseif key == "pipelines" then
    self.pipelines:activate()
  end
end

---@private
function View:_ctx()
  return vim.tbl_extend("force", {}, self.ctx, { project = self.mr.project or self.project })
end

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
    self:render()
  end)
end


---@private
function View:_args()
  return { host = self.ctx.host, project = self.project, iid = self.iid }
end

--- (Re)load everything; loaded Activity and Pipelines tabs reload too.
function View:load()
  self:_cancel()
  self.checks = { status = "loading" }
  self.reviewers = { status = "loading" }
  self.stats = { status = "loading" }
  self.commits = { status = "loading" }
  self:_run("mr", gg.merge_requests.get(self:_args()), function(mr, err)
    if err then
      self.err = err.message or tostring(err)
      return
    end
    self.mr, self.full, self.err = mr, true, nil
    self.refs = closing_refs.parse(mr.description)
    self:_load_issues()
  end)
  if not self.me then
    self:_run("me", gg.users.current({ host = self.ctx.host }), function(u)
      self.me = u and u.username or nil
    end)
  end
  self:_run("checks", gg.mr_checks.get(self:_args()), function(v, err)
    self.checks = loadable(v, err)
  end)
  self:_run("reviewers", gg.reviews.reviewers(self:_args()), function(v, err)
    self.reviewers = loadable(v, err, function(res)
      return res.reviewers or {}
    end)
  end)
  self:_run("stats", gg.mr_changes.stats(self:_args()), function(v, err)
    self.stats = loadable(v, err, function(res)
      return res.files or {}
    end)
  end)
  self:_run("commits", gg.mr_changes.commits_all(self:_args(), { limit = self.ctx.cfg.limit }), function(v, err)
    self.commits = loadable(v, err, function(res)
      return res.items or {}
    end)
  end)
  if self.activity.status ~= "idle" then
    self.activity:load()
  end
  if self.pipelines.status ~= "idle" then
    self.pipelines:load()
  end
  self:render()
end

-- the issues the description closes, per project
---@private
function View:_load_issues()
  self.issues = {}
  local by_project = {}
  for _, r in ipairs(self.refs) do
    local p = r.project or self.mr.project or self.project
    by_project[p] = by_project[p] or {}
    table.insert(by_project[p], r)
  end
  for p, refs in pairs(by_project) do
    local iids = vim.tbl_map(function(r)
      return r.iid
    end, refs)
    self:_run("issues:" .. p, gg.issues.by_iids({ host = self.ctx.host, project = p, iids = iids }), function(list)
      local found = {}
      for _, i in ipairs(list or {}) do
        found[i.iid] = i
      end
      for _, r in ipairs(refs) do
        self.issues[r.key] = found[r.iid] or false
      end
    end)
  end
end

---@private
function View:_data()
  return {
    mr = self.mr,
    project = self.project,
    checks = self.checks,
    reviewers = self.reviewers,
    refs = self.refs,
    issues = self.issues,
    now = self.ctx.now and self.ctx.now() or os.time(),
    chip_hl = highlights.chip,
    user_colors = self.ctx.cfg.user_colors,
    me = self.me or self.activity.me,
    pipeline_key = picker.first_key(self.h.keys.goto_pipeline) or nil,
    keys = self:_hint_keys(),
    editing = self.h.editing and self.h.editing.id or nil,
  }
end

---@private
function View:_hint_keys()
  local out = {}
  for name, v in pairs(self.h.keys) do
    out[name] = picker.first_key(v)
  end
  return out
end

---@private
function View:_tabs()
  local tabs = vim.deepcopy(M.TABS)
  if self.pipelines.status == "ready" then
    tabs[5].count = #self.pipelines.pipelines .. (self.pipelines.next_cursor and "+" or "")
  end
  self.h:set_tabs(tabs)
end

--- Redraw the header, sidebar and the static tabs.
function View:render()
  local h = self.h
  if h.closed then
    return
  end
  local data = self:_data()
  local narrow = not h:has_sidebar()
  local body, title = render.header(data, h:header_width(), narrow)
  h:set_header(body, title)
  if not narrow then
    h:set_sidebar(render.sidebar(data, h:sidebar_width()))
  end
  local width = h:content_width()
  local d
  if self.err and not self.full then
    d = doc.new()
    d:text(" " .. self.err, "GitlabDetailError")
  elseif not self.full then
    d = doc.new()
    d:text(" Loading…", "GitlabDetailMuted")
  else
    d = render.description(data, width - 1)
  end
  h:set_content("description", d)
  h:set_content("changes", changes.render({ width = width, status = self.stats.status, files = self.stats.value, error = self.stats.error }))
  h:set_content("commits", commits.render({
    width = width,
    status = self.commits.status,
    commits = self.commits.value,
    error = self.commits.error,
    today = self.ctx.today or date.today(),
    utc_offset = date.utc_offset(),
    user_colors = self.ctx.cfg.user_colors,
  }))
  local k = h.keys
  local ek = picker.first_key(h.keys.edit)
  h:set_hints("description", self:_open() and ek and { { key = ek, desc = "Edit" } } or {})
  h:set_hints("changes", { self.file_hint })
  h:set_hints("commits", {})
  self:_tabs()
  if self.activity.status ~= "idle" then
    self.activity:render()
  end
  if self.pipelines.status ~= "idle" then
    self.pipelines:render()
  end
end

--- `i` / `<CR>` on an issue card: open the issue.
function View:open_card()
  local info = self.h:current()
  if info and info.kind == "card" then
    local r = info.ref
    local project = r.project or self.mr.project or self.project
    require("gg.ui.detail").issue(vim.tbl_extend("force", {}, self.ctx, { project = project }), info.issue or { iid = r.iid, project = project })
  end
end

--- `gp`: open the newest pipeline of this merge request.
function View:goto_pipeline()
  local loaded = self.pipelines.pipelines
  if loaded and loaded[1] then
    return require("gg.ui.detail").pipeline(self:_ctx(), loaded[1])
  end
  local t = gg.pipelines.list({ host = self.ctx.host, project = self.project, mr_iid = self.iid }, { per_page = 1 })
  self.tasks.latest = t
  t:on_done(function(page, err)
    if self.h.closed or self.tasks.latest ~= t or not self.h:visible() then
      return
    end
    self.tasks.latest = nil
    local p = not err and page and page.items[1]
    if not p then
      vim.notify(err and ("gg.ui: " .. (err.message or tostring(err))) or "No pipelines", vim.log.levels.INFO)
      return
    end
    require("gg.ui.detail").pipeline(self:_ctx(), p)
  end)
end

return M
