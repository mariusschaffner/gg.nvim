--- The issue detail view: header, Description and Activity tabs, sidebar.
---
--- Opens at once with what the caller already has (a row of the issues
--- table), then loads the full issue, its dates, related branches and
--- merge requests in parallel; the Activity tab loads when first shown.
--- `gm` opens the milestone, `gp` the linked merge request. Edits (see
--- docs/edit_ressources.md): `i` the description, `x` a task, `gt` the
--- title, `ga` assignees, `gl` labels, `gM` milestone, `gs` / `gd` dates.
local activity = require("gg.ui.detail.activity.view")
local confirm = require("gg.ui.components.confirm")
local edit = require("gg.ui.detail.edit")
local editing = require("gg.ui.detail.editing")
local edits = require("gg.ui.detail.edits")
local fields = require("gg.ui.detail.fields")
local picker = require("gg.ui.components.picker")
local gg = require("gg")
local highlights = require("gg.ui.highlights")
local host = require("gg.ui.detail.host")
local doc = require("gg.ui.lib.doc")
local markdown = require("gg.ui.lib.markdown")
local render = require("gg.ui.detail.issue.render")

local M = {}

M.TABS = { { key = "description", label = "Description" }, { key = "activity", label = "Activity" } }

---@class gg.ui.IssueDetail
---@field ctx gg.ui.DetailCtx
---@field h gg.ui.DetailHost
---@field screen gg.ui.Screen
---@field project string
---@field iid integer
---@field issue gg.Issue
---@field full boolean the full issue (with description) has loaded
---@field status "loading"|"ready"|"error"
---@field dates gg.ui.Loadable
---@field branches gg.ui.Loadable
---@field mrs gg.ui.Loadable
local View = {}
View.__index = View

--- Open the issue detail view (called through `gg.ui.detail.issue`).
---@param ctx gg.ui.DetailCtx
---@param item gg.Issue|{ iid: integer, project?: string }
---@return gg.ui.IssueDetail
function M.open(ctx, item)
  highlights.setup()
  local self = setmetatable({
    ctx = ctx,
    project = item.project or ctx.project,
    iid = item.iid,
    issue = vim.deepcopy(item),
    full = false,
    status = "loading",
    tasks = {},
  }, View)
  self.issue.labels = self.issue.labels or {}
  self.issue.assignees = self.issue.assignees or {}
  self.h = host.new({
    stack = ctx.stack,
    cfg = ctx.cfg,
    name = "issue",
    sidebar = true,
    tabs = vim.deepcopy(M.TABS),
    on_render = function()
      self:render()
    end,
    on_refresh = function()
      self:load()
    end,
    on_tab = function(key)
      if key == "activity" and self.activity.status == "idle" then
        self.activity:load()
      end
    end,
  })
  self.screen = self.h.screen
  self.screen.teardown = function()
    self:_cancel()
    self.activity:cancel()
  end
  self.activity = activity.new(self.h, {
    tab = "activity",
    noteable = "issue",
    host = ctx.host,
    project = self.project,
    iid = self.iid,
    today = ctx.today,
    can_comment = function()
      return self:_open()
    end,
    item = function()
      return self.issue
    end,
    changed = function()
      self.ctx.stack:changed("issue")
    end,
  })
  local k = self.h.keys
  self.h:map_all(k.goto_milestone, function()
    self:goto_milestone()
  end, "Milestone")
  self.h:map_all(k.goto_mr, function()
    self:goto_mr()
  end, "Merge request")
  self.sources = fields.sources(ctx.host, self.project)
  self:_edit_keys()
  self:load()
  return self
end

-- the keys that change the issue
---@private
function View:_edit_keys()
  local h, k = self.h, self.h.keys
  h:map("description", k.edit, function()
    self:edit_description()
  end, "Edit the description")
  h:map("description", k.toggle_task, function()
    self:toggle_task()
  end, "Toggle the task")
  self.task_hint = editing.cursor_hint(h, "description", function(info)
    if info.kind == "task" and self:_open() and picker.first_key(k.toggle_task) then
      return { { "[" .. picker.first_key(k.toggle_task) .. "]", "GitlabHintKey" }, { " toggle", "GitlabHintText" } }
    end
  end)
  local all = {
    { k.edit_title, "title" },
    { k.edit_assignees, "assignees" },
    { k.edit_labels, "labels" },
    { k.edit_milestone, "milestone" },
    { k.edit_start_date, "start_date" },
    { k.edit_due_date, "due_date" },
  }
  for _, m in ipairs(all) do
    h:map_all(m[1], function()
      self:edit_field(m[2])
    end, "Edit " .. m[2])
  end
  h:map_all(k.actions, function()
    self:actions()
  end, "Actions")
  h:map_all(k.create_branch, function()
    self:create_branch()
  end, "Create a branch")
  h:map_all(k.create_mr, function()
    self:create_mr()
  end, "Create a merge request")
end

-- the project's branches, the default one first
---@private
function View:_branches(cb)
  gg.branches.list({ host = self.ctx.host, project = self.project }, { per_page = 100 }):on_done(function(page, err)
    if self.h.closed then
      return
    end
    if err then
      return edit.refuse("Cannot load the branches: " .. (err.message or tostring(err)))
    end
    local list = page.items or {}
    table.sort(list, function(a, b)
      if a.default ~= b.default then
        return a.default == true
      end
      return a.name < b.name
    end)
    cb(list)
  end)
end

--- `gb`: create a branch for the issue ("<iid>-<title>") from a branch you
--- pick (the default one first).
function View:create_branch()
  if not self.full then
    return edit.refuse("Still loading the issue")
  end
  if not self:_open() then
    return edit.refuse("Issue is closed")
  end
  local linked = self.branches.status == "ready" and self.branches.value or {}
  if #linked > 0 then
    return edit.refuse("A branch is already linked: " .. linked[1].name)
  end
  self:_branches(function(list)
    vim.ui.select(list, {
      prompt = "Create branch from",
      format_item = function(b)
        return b.default and (b.name .. "  (default)") or b.name
      end,
    }, function(from)
      if not from then
        return
      end
      vim.ui.input({ prompt = "Branch name: ", default = edits.branch_name(self.iid, self.issue.title) }, function(name)
        name = name and vim.trim(name) or ""
        if name == "" then
          return
        end
        edit.run({
          what = "branch",
          busy = "Creating " .. name .. "…",
          success = ("Branch created: %s (from %s)"):format(name, from.name),
          task = function()
            return gg.branches.create({ host = self.ctx.host, project = self.project, branch = name, ref = from.name })
          end,
          apply = function(b)
            local list_ = self.branches.status == "ready" and self.branches.value or {}
            table.insert(list_, b)
            self.branches = { status = "ready", value = list_ }
          end,
          alive = function()
            return not self.h.closed
          end,
          changed = function()
            self:_changed()
          end,
          render = function()
            self:render()
          end,
        })
      end)
    end)
  end)
end

--- `gP`: a new merge request for the issue (a form; `<C-s>` creates it).
function View:create_mr()
  if not self.full then
    return edit.refuse("Still loading the issue")
  end
  if not self:_open() then
    return edit.refuse("Issue is closed")
  end
  local function open(source)
    require("gg.ui.detail").new_merge_request(self:_ctx(), {
      source_branch = source,
      title = ('Draft: Resolve "%s"'):format(self.issue.title or ""),
      description = "Closes #" .. tostring(self.iid),
    })
  end
  local linked = self.branches.status == "ready" and self.branches.value or {}
  if #linked > 0 then
    return open(linked[1].name)
  end
  self:_branches(function(list)
    vim.ui.select(vim.tbl_filter(function(b)
      return not b.default
    end, list), {
      prompt = "Source branch",
      format_item = function(b)
        return b.name
      end,
    }, function(b)
      if b then
        open(b.name)
      end
    end)
  end)
end

--- `A`: close or reopen the issue.
function View:actions()
  if not self.full then
    return edit.refuse("Still loading the issue")
  end
  local open = self:_open()
  confirm.menu("Issue #" .. tostring(self.iid), {
    {
      label = open and "Close issue" or "Reopen issue",
      run = function()
        edit.run({
          what = "state",
          busy = open and "Closing issue…" or "Reopening issue…",
          success = open and "Issue closed" or "Issue reopened",
          task = function()
            return self:_update({ state_event = open and "close" or "reopen" })
          end,
          apply = function(issue)
            self:_take(issue)
          end,
          alive = function()
            return not self.h.closed
          end,
          changed = function()
            self:_changed()
          end,
          render = function()
            self:render()
          end,
        })
      end,
    },
  })
end

---@private
function View:_open()
  return self.issue.state ~= "closed"
end

---@private
function View:_changed()
  self.ctx.stack:changed("issue")
  -- the change shows up as an event in the activity
  if self.activity.status ~= "idle" then
    self.activity:load()
  end
end

-- the issue update payload for a field
---@private
function View:_update(fields_)
  return gg.issues.update(vim.tbl_extend("force", self:_args(), fields_))
end

---@private
function View:_take(issue)
  -- the update answer (REST) lacks nothing the views use, but keep the
  -- project path the view was opened with
  issue.project = issue.project or self.issue.project or self.project
  self.issue = issue
end

--- `i`: edit the description in place (fetched again first).
function View:edit_description()
  if not self:_open() then
    return edit.refuse("Issue is closed")
  end
  local info = self.h:current()
  editing.text(self.h, {
    what = "description",
    cursor = info and info.src,
    load = function(cb)
      gg.issues.get(self:_args()):on_done(function(issue, err)
        cb(issue and issue.description or nil, err)
      end)
    end,
    save = function(text)
      return self:_update({ description = text })
    end,
    apply = function(issue)
      self:_take(issue)
    end,
    changed = function()
      self:_changed()
    end,
    render = function()
      self:render()
    end,
  })
end

--- `x`: toggle the task under the cursor (shown at once, undone on error).
function View:toggle_task()
  local info = self.h:current()
  if not (info and info.kind == "task" and info.src) then
    return
  end
  if not self:_open() then
    return edit.refuse("Issue is closed")
  end
  local old = self.issue.description or ""
  local new = edits.toggle_task(old, info.src)
  if not new then
    return
  end
  self.issue.description = new
  self:render()
  edit.run({
    what = "task",
    task = function()
      return self:_update({ description = new })
    end,
    apply = function(issue)
      self:_take(issue)
    end,
    rollback = function()
      self.issue.description = old
    end,
    alive = function()
      return not self.h.closed
    end,
    changed = function()
      self:_changed()
    end,
    render = function()
      self:render()
    end,
  })
end

--- Edit one field: "title", "assignees", "labels", "milestone",
--- "start_date" or "due_date".
---@param name string
function View:edit_field(name)
  if not self.full then
    return edit.refuse("Still loading the issue")
  end
  if name ~= "labels" and not self:_open() then
    return edit.refuse("Issue is closed")
  end
  local base = {
    h = self.h,
    changed = function()
      self:_changed()
    end,
    render = function()
      self:render()
    end,
    apply = function(issue)
      self:_take(issue)
    end,
  }
  local function with(extra)
    return vim.tbl_extend("force", base, extra)
  end
  if name == "title" then
    fields.title(with({
      text = self.issue.title or "",
      save = function(t)
        return self:_update({ title = t })
      end,
    }))
  elseif name == "assignees" then
    fields.people(with({
      what = "assignees",
      id = "assignees",
      users = self.issue.assignees,
      source = self.sources.members,
      save = function(ids)
        return self:_update({ assignee_ids = ids })
      end,
    }))
  elseif name == "labels" then
    fields.labels(with({
      labels = self.issue.labels,
      source = self.sources.labels,
      save = function(p)
        return self:_update({ add_labels = p.add, remove_labels = p.remove })
      end,
    }))
  elseif name == "milestone" then
    fields.milestone(with({
      milestone = self.issue.milestone,
      source = self.sources.milestones,
      save = function(id)
        return self:_update({ milestone_id = id })
      end,
    }))
  else
    if self.dates.status ~= "ready" then
      return edit.refuse("Dates still loading")
    end
    local d = self.dates.value or {}
    fields.date(with({
      id = name,
      label = name == "start_date" and "start date" or "due date",
      pane = "sidebar",
      date = d[name],
      save = function(value)
        return gg.work_items.update_dates(vim.tbl_extend("force", self:_args(), {
          work_item_id = d.work_item_id,
          [name] = value,
        }))
      end,
      apply = function(dates)
        self.dates = { status = "ready", value = dates }
      end,
    }))
  end
end

---@private
function View:_cancel()
  for _, t in pairs(self.tasks) do
    t:cancel()
  end
  self.tasks = {}
end

---@private
function View:_args()
  return { host = self.ctx.host, project = self.project, iid = self.iid }
end

-- start `t`; `done(value, err)` runs only while this load is current
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

local function loadable(v, err, map)
  if err then
    return { status = "error", error = err.message or tostring(err) }
  end
  return { status = "ready", value = map and map(v) or v }
end

--- (Re)load everything; a loaded Activity tab reloads too.
function View:load()
  self:_cancel()
  local limit = self.ctx.cfg.limit
  self.status = self.full and "ready" or "loading"
  self.dates = { status = "loading" }
  self.branches = { status = "loading" }
  self.mrs = { status = "loading" }
  self:_run("issue", gg.issues.get(self:_args()), function(issue, err)
    if err then
      self.status, self.err = "error", err.message or tostring(err)
      return
    end
    self.issue, self.full, self.status = issue, true, "ready"
  end)
  self:_run("dates", gg.work_items.dates(self:_args()), function(v, err)
    self.dates = loadable(v, err)
  end)
  self:_run("branches", gg.branches.related_to_issue_all(self:_args(), { limit = 20 }), function(v, err)
    self.branches = loadable(v, err, function(res)
      return res.items
    end)
  end)
  self:_run("mrs", gg.merge_requests.related_to_issue_all(self:_args(), { limit = math.min(limit, 100) }), function(v, err)
    self.mrs = loadable(v, err, function(res)
      return res.items
    end)
  end)
  if self.activity.status ~= "idle" then
    self.activity:load()
  end
  self:render()
end

---@private
function View:_data()
  return {
    issue = self.issue,
    project = self.project,
    dates = self.dates,
    branches = self.branches,
    mrs = self.mrs,
    now = self.ctx.now and self.ctx.now() or os.time(),
    chip_hl = highlights.chip,
    user_colors = self.ctx.cfg.user_colors,
    me = self.activity.me,
    keys = self:_hint_keys(),
    editing = self.h.editing and self.h.editing.id or nil,
  }
end

-- first key of each edit keymap, for the sidebar hints
---@private
function View:_hint_keys()
  local out = {}
  for name, v in pairs(self.h.keys) do
    out[name] = picker.first_key(v)
  end
  return out
end

--- Redraw the header, sidebar and the Description tab.
function View:render()
  local h = self.h
  if h.closed then
    return
  end
  local data = self:_data()
  local body, title = render.header(data, h:header_width(), not h:has_sidebar())
  h:set_header(body, title)
  if h:has_sidebar() then
    h:set_sidebar(render.sidebar(data, h:sidebar_width()))
  end
  local ek = picker.first_key(h.keys.edit)
  h:set_hints("description", self:_open() and ek and { { key = ek, desc = "Edit" } } or {})
  local d
  if self.status == "error" then
    d = doc.new()
    d:text(" " .. (self.err or "Failed to load the issue"), "GitlabDetailError")
  elseif not self.full then
    d = doc.new()
    d:text(" Loading…", "GitlabDetailMuted")
  else
    d = markdown.render(self.issue.description, { width = h:content_width() - 1 })
  end
  h:set_content("description", d)
  if self.activity.status ~= "idle" then
    self.activity:render()
  end
end

---@private
function View:_ctx()
  return vim.tbl_extend("force", {}, self.ctx, { project = self.issue.project or self.project })
end

--- `gm`: open the issue's milestone.
function View:goto_milestone()
  if not self.issue.milestone then
    vim.notify("No milestone", vim.log.levels.INFO)
    return
  end
  require("gg.ui.detail").milestone(self:_ctx(), self.issue.milestone)
end

--- `gp`: open the linked merge request (a choice when there are several).
function View:goto_mr()
  local mrs = self.mrs and self.mrs.status == "ready" and self.mrs.value or {}
  if #mrs == 0 then
    vim.notify(self.mrs and self.mrs.status == "loading" and "Still loading merge requests" or "No linked merge requests", vim.log.levels.INFO)
    return
  end
  local function open(mr)
    if mr then
      require("gg.ui.detail").merge_request(self:_ctx(), mr)
    end
  end
  if #mrs == 1 then
    return open(mrs[1])
  end
  vim.ui.select(mrs, {
    prompt = "Linked merge requests",
    format_item = function(mr)
      return ("!%d %s"):format(mr.iid, mr.title or "")
    end,
  }, open)
end

return M
