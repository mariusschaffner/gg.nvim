--- The issue detail view: header, Description and Activity tabs, sidebar.
---
--- Opens at once with what the caller already has (a row of the issues
--- table), then loads the full issue, its dates, related branches and
--- merge requests in parallel; the Activity tab loads when first shown.
--- Read-only. `gm` opens the milestone, `gp` the linked merge request.
local activity = require("gg.ui.detail.activity.view")
local gg = require("gg")
local highlights = require("gg.ui.highlights")
local host = require("gg.ui.detail.host")
local doc = require("gg.ui.lib.doc")
local markdown = require("gg.ui.lib.markdown")
local picker = require("gg.ui.components.picker")
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
    on_loaded = function(n)
      self:_tab_counts(n)
    end,
  })
  local k = self.h.keys
  self.h:map_all(k.goto_milestone, function()
    self:goto_milestone()
  end, "Milestone")
  self.h:map_all(k.goto_mr, function()
    self:goto_mr()
  end, "Merge request")
  self:_tab_counts(self.issue.user_notes_count)
  self:load()
  return self
end

---@private
function View:_tab_counts(comments)
  local tabs = vim.deepcopy(M.TABS)
  tabs[2].count = comments
  self.h:set_tabs(tabs)
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
    self:_tab_counts(self.activity.status == "ready" and self.activity:comment_count() or issue.user_notes_count)
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
  }
end

--- Redraw the header, sidebar and the Description tab.
function View:render()
  local h = self.h
  if h.closed then
    return
  end
  local data = self:_data()
  local body, title = render.header(data, h:header_width(), not h:has_sidebar())
  local k = h.keys
  local hints = {}
  if self.issue.milestone and picker.first_key(k.goto_milestone) then
    table.insert(hints, { key = picker.first_key(k.goto_milestone), desc = "Milestone" })
  end
  if self.mrs and self.mrs.status == "ready" and #self.mrs.value > 0 and picker.first_key(k.goto_mr) then
    table.insert(hints, { key = picker.first_key(k.goto_mr), desc = "Merge request" })
  end
  h:set_header(body, title)
  if h:has_sidebar() then
    h:set_sidebar(render.sidebar(data, h:sidebar_width()))
  end
  h:set_hints("description", hints)
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
