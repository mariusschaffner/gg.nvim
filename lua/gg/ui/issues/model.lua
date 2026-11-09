--- Issues picker model: tab + filter + grouping + ordering. Pure.
---
--- Issues without a milestone are top level: each is its own block, listed
--- first. Then one block per milestone that has a matching issue.
local date = require("gg.ui.lib.date")
local filter = require("gg.ui.issues.filter")

local M = {}

---@alias gg.ui.Tab "opened"|"closed"|"all"

M.TABS = { "opened", "closed", "all" }

---@class gg.ui.MilestoneInfo
---@field ref gg.MilestoneRef
---@field name string "%" plus the first word of the title ("%2026.11")
---@field rest string the rest of the title ("Patch cycle")
---@field due { text: string, tone: gg.ui.DueTone }
---@field progress { closed: integer, total: integer } the whole milestone, any state

---@class gg.ui.Block
---@field kind "top"|"milestone"
---@field key string "top:<iid>" or "ms:<id>"
---@field issues gg.Issue[]
---@field milestone? gg.ui.MilestoneInfo
---@field continued? boolean set by paginate on a block split across pages

---@class gg.ui.IssuesModel
---@field tab gg.ui.Tab
---@field counts { opened: integer, closed: integer, all: integer } per tab, unfiltered
---@field matching integer issues in the active tab that match the filter
---@field total integer issues in the active tab
---@field filtered boolean a filter is active
---@field has_milestones boolean some loaded issue (any tab, any filter) has a milestone
---@field blocks gg.ui.Block[]

---@class gg.ui.ModelOpts
---@field tab? gg.ui.Tab default "opened"
---@field query? string
---@field today gg.ui.Date
---@field order? gg.ui.Order

--- Open tab membership: "locked" issues are open.
---@param issue gg.Issue
---@return boolean
function M.is_closed(issue)
  return issue.state == "closed"
end

local function in_tab(issue, tab)
  if tab == "all" then
    return true
  end
  return M.is_closed(issue) == (tab == "closed")
end

-- a < b with nil last
local function nil_last(a, b)
  if a == b then
    return nil
  end
  if a == nil then
    return false
  end
  if b == nil then
    return true
  end
  return a < b
end

--- Default order of top-level issues: updated_at desc, then iid desc.
---@param a gg.Issue
---@param b gg.Issue
---@return boolean
function M.order_top(a, b)
  if a.updated_at ~= b.updated_at then
    return (a.updated_at or "") > (b.updated_at or "")
  end
  return (a.iid or 0) > (b.iid or 0)
end

--- Default order of milestones: due_date asc (none last), then title.
---@param a gg.MilestoneRef
---@param b gg.MilestoneRef
---@return boolean
function M.order_milestones(a, b)
  local r = nil_last(a.due_date, b.due_date)
  if r ~= nil then
    return r
  end
  if (a.title or "") ~= (b.title or "") then
    return (a.title or "") < (b.title or "")
  end
  return (a.id or 0) < (b.id or 0)
end

--- Default order inside a milestone: due_date asc (none last), then iid desc.
---@param a gg.Issue
---@param b gg.Issue
---@return boolean
function M.order_issues(a, b)
  local r = nil_last(a.due_date, b.due_date)
  if r ~= nil then
    return r
  end
  return (a.iid or 0) > (b.iid or 0)
end

local function milestone_key(ref)
  return ref.id and ("ms:" .. ref.id) or ("ms:" .. (ref.title or "?"))
end

--- Split "2026.11 Patch cycle" into "%2026.11" and "Patch cycle".
---@param title string|nil
---@return string name
---@return string rest
function M.split_title(title)
  local first, rest = (title or ""):match("^%s*(%S+)%s*(.-)%s*$")
  return "%" .. (first or ""), rest or ""
end

--- Closed/total of every milestone, counted from `issues` (all states).
--- The fallback when GitLab returns no `issue_stats`.
---@param issues gg.Issue[]
---@return table<string, { closed: integer, total: integer }>
function M.count_progress(issues)
  local out = {}
  for _, issue in ipairs(issues) do
    if issue.milestone then
      local key = milestone_key(issue.milestone)
      local p = out[key] or { closed = 0, total = 0 }
      p.total = p.total + 1
      if M.is_closed(issue) then
        p.closed = p.closed + 1
      end
      out[key] = p
    end
  end
  return out
end

--- Build the model for one tab and filter.
---@param issues gg.Issue[] every fetched issue, all states
---@param opts gg.ui.ModelOpts
---@return gg.ui.IssuesModel
function M.build(issues, opts)
  local tab = opts.tab or "opened"
  local order = opts.order or {}
  local tokens = filter.parse(opts.query)
  local counts = { opened = 0, closed = 0, all = #issues }
  local has_milestones = false
  for _, issue in ipairs(issues) do
    has_milestones = has_milestones or issue.milestone ~= nil
    if M.is_closed(issue) then
      counts.closed = counts.closed + 1
    else
      counts.opened = counts.opened + 1
    end
  end
  local counted = M.count_progress(issues)

  local total, matching = 0, 0
  local top, groups, refs = {}, {}, {}
  for _, issue in ipairs(issues) do
    if in_tab(issue, tab) then
      total = total + 1
      if filter.matches(issue, tokens) then
        matching = matching + 1
        if issue.milestone then
          local key = milestone_key(issue.milestone)
          if not groups[key] then
            groups[key] = {}
            table.insert(refs, issue.milestone)
          end
          table.insert(groups[key], issue)
        else
          table.insert(top, issue)
        end
      end
    end
  end

  table.sort(top, order.top or M.order_top)
  table.sort(refs, order.milestones or M.order_milestones)

  local blocks = {}
  for _, issue in ipairs(top) do
    table.insert(blocks, { kind = "top", key = "top:" .. tostring(issue.iid), issues = { issue } })
  end
  for _, ref in ipairs(refs) do
    local key = milestone_key(ref)
    local list = groups[key]
    table.sort(list, order.issues or M.order_issues)
    local name, rest = M.split_title(ref.title)
    local due_text, tone = date.due(ref.due_date, opts.today, ref.state == "closed")
    local stats = ref.issue_stats
    table.insert(blocks, {
      kind = "milestone",
      key = key,
      issues = list,
      milestone = {
        ref = ref,
        name = name,
        rest = rest,
        due = { text = due_text, tone = tone },
        progress = stats and { closed = stats.closed, total = stats.total } or counted[key] or { closed = 0, total = 0 },
      },
    })
  end

  return {
    tab = tab,
    counts = counts,
    matching = matching,
    total = total,
    filtered = #tokens > 0,
    has_milestones = has_milestones,
    blocks = blocks,
  }
end

return M
