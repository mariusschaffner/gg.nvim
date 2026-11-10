--- The milestone detail view: header with the date strip, Description,
--- Work items and Merge requests tabs, and a progress sidebar.
---
--- The work items and merge requests are drawn by the issues and merge
--- requests tables' own renderers (without the milestone grouping); `i` /
--- `<CR>` opens the row under the cursor. Edits: `i` the description, `gt`
--- the title, `gs` / `gd` the dates (over the header strip), `A` close /
--- reopen.
local confirm = require("gg.ui.components.confirm")
local date = require("gg.ui.lib.date")
local edit = require("gg.ui.detail.edit")
local editing = require("gg.ui.detail.editing")
local fields = require("gg.ui.detail.fields")
local detail_table = require("gg.ui.components.detail_table")
local doc = require("gg.ui.lib.doc")
local gg = require("gg")
local highlights = require("gg.ui.highlights")
local host = require("gg.ui.detail.host")
local issues_model = require("gg.ui.issues.model")
local issues_render = require("gg.ui.issues.render")
local markdown = require("gg.ui.lib.markdown")
local mr_model = require("gg.ui.merge_requests.model")
local mr_render = require("gg.ui.merge_requests.render")
local picker = require("gg.ui.components.picker")
local render = require("gg.ui.detail.milestone.render")

local M = {}

M.TABS = {
  { key = "description", label = "Description" },
  { key = "work_items", label = "Work items" },
  { key = "merge_requests", label = "Merge requests" },
}

---@class gg.ui.MilestoneDetail
---@field ctx gg.ui.DetailCtx
---@field h gg.ui.DetailHost
---@field screen gg.ui.Screen
---@field milestone gg.Milestone
---@field full boolean
---@field issues gg.ui.Loadable
---@field mrs gg.ui.Loadable
---@field summaries table<integer, gg.ui.MrSummaryEntry>
local View = {}
View.__index = View

--- Open the milestone detail view (called through `gg.ui.detail.milestone`).
---@param ctx gg.ui.DetailCtx
---@param item gg.MilestoneRef|gg.Milestone
---@return gg.ui.MilestoneDetail
function M.open(ctx, item)
  highlights.setup()
  local self = setmetatable({
    ctx = ctx,
    project = item.project or ctx.project,
    milestone = vim.deepcopy(item),
    full = false,
    tasks = {},
    summaries = {},
  }, View)
  self.h = host.new({
    stack = ctx.stack,
    cfg = ctx.cfg,
    name = "milestone",
    sidebar = true,
    tabs = vim.deepcopy(M.TABS),
    on_render = function()
      self:render()
    end,
    on_refresh = function()
      self:load()
    end,
    on_tab = function(key)
      if self.tables[key] then
        self.tables[key]:restore()
      end
    end,
  })
  self.screen = self.h.screen
  self.screen.teardown = function()
    self:_cancel()
  end
  self.tables = {
    work_items = detail_table.new(self.h, "work_items", {
      key_of = function(row)
        return row.issue and row.issue.iid or nil
      end,
      on_open = function(row)
        if row.issue then
          require("gg.ui.detail").issue(self:_ctx(row.issue.project), row.issue)
        end
      end,
      open_desc = "Open issue",
    }),
    merge_requests = detail_table.new(self.h, "merge_requests", {
      key_of = function(row)
        return row.mr and row.mr.iid or nil
      end,
      on_open = function(row)
        if row.mr then
          require("gg.ui.detail").merge_request(self:_ctx(row.mr.project), row.mr)
        end
      end,
      open_desc = "Open merge request",
    }),
  }
  self:_edit_keys()
  self:load()
  return self
end

---@private
function View:_edit_keys()
  local h, k = self.h, self.h.keys
  h:map("description", k.edit, function()
    self:edit_description()
  end, "Edit the description")
  h:map_all(k.edit_title, function()
    self:edit_field("title")
  end, "Edit the title")
  h:map_all(k.edit_start_date, function()
    self:edit_field("start_date")
  end, "Edit the start date")
  h:map_all(k.edit_due_date, function()
    self:edit_field("due_date")
  end, "Edit the due date")
  h:map_all(k.actions, function()
    self:actions()
  end, "Actions")
end

-- the project a milestone can be changed in (group milestones cannot)
---@private
function View:_editable()
  if not self.full then
    return nil, "Still loading the milestone"
  end
  if self.milestone.group and not self.milestone.project then
    return nil, "Group milestones are changed in their group"
  end
  return self.milestone.project or self.project
end

---@private
function View:_update(project, fields_)
  return gg.milestones.update(vim.tbl_extend("force", { host = self.ctx.host, project = project, id = self.milestone.id }, fields_))
end

-- take an update's answer (REST: fewer fields) into the milestone
---@private
function View:_take(result, sent)
  for k, v in pairs(result or {}) do
    if k ~= "project" and k ~= "group" then
      self.milestone[k] = v
    end
  end
  for k, v in pairs(sent or {}) do
    if k ~= "state_event" then
      self.milestone[k] = v ~= false and v or nil
    end
  end
end

---@private
function View:_changed()
  self.ctx.stack:changed("milestone")
end

--- `i`: edit the description in place (fetched again first).
function View:edit_description()
  local project, why = self:_editable()
  if not project then
    return edit.refuse(why)
  end
  local info = self.h:current()
  editing.text(self.h, {
    what = "description",
    cursor = info and info.src,
    load = function(cb)
      gg.milestones.get({ host = self.ctx.host, id = self.milestone.id }):on_done(function(m, err)
        cb(m and m.description or nil, err)
      end)
    end,
    save = function(text)
      return self:_update(project, { description = text })
    end,
    apply = function(m)
      self:_take(m)
    end,
    changed = function()
      self:_changed()
    end,
    render = function()
      self:render()
    end,
  })
end

--- Edit "title", "start_date" or "due_date".
---@param name string
function View:edit_field(name)
  local project, why = self:_editable()
  if not project then
    return edit.refuse(why)
  end
  local base = {
    h = self.h,
    changed = function()
      self:_changed()
    end,
    render = function()
      self:render()
    end,
  }
  if name == "title" then
    fields.title(vim.tbl_extend("force", base, {
      text = self.milestone.title or "",
      required = true,
      save = function(t)
        return self:_update(project, { title = t })
      end,
      apply = function(m)
        self:_take(m)
      end,
    }))
  else
    fields.date(vim.tbl_extend("force", base, {
      id = name,
      label = name == "start_date" and "start date" or "due date",
      pane = "header",
      date = self.milestone[name],
      save = function(value)
        self._sent = { [name] = value }
        return self:_update(project, { [name] = value })
      end,
      apply = function(m)
        self:_take(m, self._sent)
      end,
    }))
  end
end

--- `A`: close or reopen the milestone.
function View:actions()
  local project, why = self:_editable()
  if not project then
    return edit.refuse(why)
  end
  local closed = self.milestone.state == "closed"
  local event = closed and "activate" or "close"
  confirm.menu("Milestone %" .. tostring(self.milestone.id), {
    {
      label = closed and "Reopen milestone" or "Close milestone",
      run = function()
        edit.run({
          what = "milestone",
          busy = closed and "Reopening milestone…" or "Closing milestone…",
          success = closed and "Milestone reopened" or "Milestone closed",
          task = function()
            return self:_update(project, { state_event = event })
          end,
          apply = function(m)
            self:_take(m)
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
function View:_ctx(project)
  return vim.tbl_extend("force", {}, self.ctx, { project = project or self.project })
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

--- (Re)load the milestone, its issues and merge requests.
function View:load()
  self:_cancel()
  local limit = self.ctx.cfg.limit
  self.issues = { status = "loading" }
  self.mrs = { status = "loading" }
  local host_name = self.ctx.host
  self:_run("milestone", gg.milestones.get({ host = host_name, id = self.milestone.id }), function(m, err)
    if err then
      self.err = err.message or tostring(err)
      return
    end
    self.milestone, self.full, self.err = m, true, nil
  end)
  local items = { host = host_name, project = self.project, title = self.milestone.title }
  self:_run("issues", gg.milestones.issues_all(items, { limit = limit }), function(res, err)
    self.issues = err and { status = "error", error = err.message or tostring(err) } or { status = "ready", value = res.items }
  end)
  self:_run("mrs", gg.milestones.merge_requests_all(items, { limit = limit }), function(res, err)
    self.mrs = err and { status = "error", error = err.message or tostring(err) } or { status = "ready", value = res.items }
    if not err then
      self:_load_summaries(res.items)
    end
  end)
  self:render()
end

-- head pipelines and diff stats for the merge requests table
---@private
function View:_load_summaries(mrs)
  self.summaries = {}
  local max = gg.merge_requests.SUMMARIES_MAX or 20
  for i = 1, #mrs, max do
    local iids = {}
    for j = i, math.min(#mrs, i + max - 1) do
      table.insert(iids, mrs[j].iid)
    end
    self:_run("summaries:" .. i, gg.merge_requests.summaries({ host = self.ctx.host, project = self.project, iids = iids }), function(list, err)
      local by = {}
      for _, s in ipairs(list or {}) do
        by[s.iid] = s
      end
      for _, iid in ipairs(iids) do
        self.summaries[iid] = { summary = by[iid], error = err ~= nil or nil }
      end
    end)
  end
end

---@private
function View:_data()
  return {
    milestone = self.milestone,
    project = self.project,
    issues = self.issues,
    mrs = self.mrs,
    today = self.ctx.today or date.today(),
    now = self.ctx.now and self.ctx.now() or os.time(),
  }
end

-- the loadable as the table renderers' status
local function status_of(l)
  return l.status == "ready" and "ready" or l.status
end

--- Redraw everything.
function View:render()
  local h = self.h
  if h.closed then
    return
  end
  local data = self:_data()
  local body, title = render.header(data, h:header_width(), not h:has_sidebar())
  local k = h.keys
  local editable = self:_editable() ~= nil
  local date_hints = editable and vim.tbl_filter(function(x)
    return x.key ~= nil
  end, {
    { key = picker.first_key(k.edit_start_date), desc = "Start" },
    { key = picker.first_key(k.edit_due_date), desc = "Due" },
  }) or {}
  h:set_header(body, title, #date_hints > 0 and require("gg.ui.lib.hint").chunks(date_hints) or nil)
  if h:has_sidebar() then
    h:set_sidebar(render.sidebar(data, h:sidebar_width()))
  end

  local d
  if self.err and not self.full then
    d = doc.new()
    d:text(" " .. self.err, "GitlabDetailError")
  elseif not self.full then
    d = doc.new()
    d:text(" Loading…", "GitlabDetailMuted")
  else
    d = markdown.render(self.milestone.description, { width = h:content_width() - 1 })
  end
  h:set_content("description", d)

  local width = h:content_width()
  -- work items: the issues table without the milestone column
  local issues_mdl
  if self.issues.status == "ready" then
    local list = vim.tbl_map(function(i)
      local c = vim.tbl_extend("force", {}, i)
      c.milestone = nil
      return c
    end, self.issues.value)
    issues_mdl = issues_model.build(list, { tab = "all", today = data.today, order = self.ctx.cfg.order })
  end
  self.tables.work_items:set(issues_render.render({
    width = width,
    status = status_of(self.issues),
    tab = "all",
    model = issues_mdl,
    page = issues_mdl and { blocks = issues_mdl.blocks, count = issues_mdl.matching } or nil,
    error = self.issues.error,
    no_tabs = true,
    label_hl = highlights.label,
    retry_key = picker.first_key(h.keys.refresh) or false,
  }))

  local mr_mdl
  if self.mrs.status == "ready" then
    mr_mdl = mr_model.build(self.mrs.value, { tab = "all" })
  end
  self.tables.merge_requests:set(mr_render.render({
    width = width,
    status = status_of(self.mrs),
    tab = "all",
    model = mr_mdl,
    page = mr_mdl and { rows = mr_mdl.rows, count = #mr_mdl.rows } or nil,
    error = self.mrs.error,
    summaries = self.summaries,
    user_colors = self.ctx.cfg.user_colors,
    no_tabs = true,
    retry_key = picker.first_key(h.keys.refresh) or false,
  }))

  local open = picker.first_key(k.open_item)
  local ek = picker.first_key(k.edit)
  h:set_hints("description", editable and ek and { { key = ek, desc = "Edit" } } or {})
  h:set_hints("work_items", { { key = open, desc = "Issue" } })
  h:set_hints("merge_requests", { { key = open, desc = "Merge request" } })
end

return M
