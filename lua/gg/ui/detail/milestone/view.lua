--- The milestone detail view: header with the date strip, Description,
--- Work items and Merge requests tabs, and a progress sidebar.
---
--- The work items and merge requests are drawn by the issues and merge
--- requests tables' own renderers (without the milestone grouping); `i` /
--- `<CR>` opens the row under the cursor, `L` / `H` switch their state tabs.
--- Read-only.
local date = require("gg.ui.lib.date")
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
---@field issue_tab gg.ui.Tab
---@field mr_tab gg.ui.MrTab
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
    issue_tab = "all",
    mr_tab = "all",
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
  local k = self.h.keys
  for key, field in pairs({ work_items = "issue_tab", merge_requests = "mr_tab" }) do
    local tabs = key == "work_items" and issues_model.TABS or mr_model.TABS
    local function cycle(dir)
      local idx = 1
      for i, t in ipairs(tabs) do
        if t == self[field] then
          idx = i
        end
      end
      self[field] = tabs[(idx - 1 + dir) % #tabs + 1]
      self:render()
    end
    self.h:map(key, k.next_tab, function()
      cycle(1)
    end, "Next state")
    self.h:map(key, k.prev_tab, function()
      cycle(-1)
    end, "Previous state")
  end
  self:load()
  return self
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
  h:set_header(body, title)
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
    issues_mdl = issues_model.build(list, { tab = self.issue_tab, today = data.today, order = self.ctx.cfg.order })
  end
  self.tables.work_items:set(issues_render.render({
    width = width,
    status = status_of(self.issues),
    tab = self.issue_tab,
    model = issues_mdl,
    page = issues_mdl and { blocks = issues_mdl.blocks, count = issues_mdl.matching } or nil,
    error = self.issues.error,
    label_hl = highlights.label,
    retry_key = picker.first_key(h.keys.refresh) or false,
  }))

  local mr_mdl
  if self.mrs.status == "ready" then
    mr_mdl = mr_model.build(self.mrs.value, { tab = self.mr_tab })
  end
  self.tables.merge_requests:set(mr_render.render({
    width = width,
    status = status_of(self.mrs),
    tab = self.mr_tab,
    model = mr_mdl,
    page = mr_mdl and { rows = mr_mdl.rows, count = #mr_mdl.rows } or nil,
    error = self.mrs.error,
    summaries = self.summaries,
    user_colors = self.ctx.cfg.user_colors,
    retry_key = picker.first_key(h.keys.refresh) or false,
  }))

  local k = h.keys
  local open = picker.first_key(k.open_item)
  local states = { { key = picker.first_key(k.next_tab), desc = "State" } }
  h:set_hints("work_items", vim.list_extend({ { key = open, desc = "Issue" } }, states))
  h:set_hints("merge_requests", vim.list_extend({ { key = open, desc = "Merge request" } }, states))
  local tabs = vim.deepcopy(M.TABS)
  if self.issues.status == "ready" then
    tabs[2].count = #self.issues.value
  end
  if self.mrs.status == "ready" then
    tabs[3].count = #self.mrs.value
  end
  h:set_tabs(tabs)
end

return M
