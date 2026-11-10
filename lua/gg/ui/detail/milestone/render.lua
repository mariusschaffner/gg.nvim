--- The milestone detail view's header and sidebar. Pure.
---
--- Work items are bucketed by workflow: a closed issue is done; an open one
--- follows its `WF:Doing` / `WF:Done` / `WF:To do` label, and is to do
--- without one.
local date = require("gg.ui.lib.date")
local header = require("gg.ui.detail.header")
local progress = require("gg.ui.lib.progress")
local sidebar = require("gg.ui.detail.sidebar")
local text = require("gg.ui.lib.text")
local timeline = require("gg.ui.detail.milestone.timeline")

local M = {}

---@alias gg.ui.Bucket "todo"|"doing"|"done"

--- The workflow bucket of an issue.
---@param issue gg.Issue
---@return gg.ui.Bucket
function M.bucket(issue)
  if issue.state == "closed" then
    return "done"
  end
  for _, l in ipairs(issue.labels or {}) do
    local v = tostring(l.name or ""):match("^%s*[Ww][Ff]%s*:+%s*(.-)%s*$")
    if v then
      v = v:lower():gsub("%s+", " ")
      if v == "doing" then
        return "doing"
      elseif v == "done" then
        return "done"
      elseif v == "todo" or v == "to do" then
        return "todo"
      end
    end
  end
  return "todo"
end

---@class gg.ui.MilestoneCounts
---@field todo integer
---@field doing integer
---@field done integer
---@field total integer
---@field unassigned integer open issues without an assignee
---@field in_progress gg.Issue[] the doing bucket

--- Count the work items.
---@param issues gg.Issue[]
---@return gg.ui.MilestoneCounts
function M.counts(issues)
  local c = { todo = 0, doing = 0, done = 0, total = #issues, unassigned = 0, in_progress = {} }
  for _, i in ipairs(issues) do
    local b = M.bucket(i)
    c[b] = c[b] + 1
    if b == "doing" then
      table.insert(c.in_progress, i)
    end
    if i.state ~= "closed" and #(i.assignees or {}) == 0 then
      c.unassigned = c.unassigned + 1
    end
  end
  return c
end

---@class gg.ui.MilestoneDetailData
---@field milestone gg.Milestone
---@field project string
---@field issues gg.ui.Loadable gg.Issue[]
---@field mrs gg.ui.Loadable gg.MergeRequest[]
---@field today gg.ui.Date
---@field now integer

--- The header: the body (pill, title, date strip) and the border title.
---@param data gg.ui.MilestoneDetailData
---@param width integer
---@param narrow boolean
---@return gg.ui.Doc body
---@return gg.ui.Chunk[] title
function M.header(data, width, narrow)
  local m = data.milestone
  local strip
  if narrow then
    if data.issues.status == "ready" then
      local c = M.counts(data.issues.value)
      local parts = {
        ("%d/%d closed"):format(c.done, c.total),
        ("%d doing"):format(c.doing),
        ("%d unassigned"):format(c.unassigned),
      }
      if data.mrs.status == "ready" then
        table.insert(parts, ("%d MRs"):format(#data.mrs.value))
      end
      strip = table.concat(parts, " · ")
    end
  end
  local body = header.build({
    width = width,
    pill = timeline.pill(m, data.today),
    title = m.title or "",
    ref = "%" .. tostring(m.id),
    strip = strip,
    extra = timeline.strip(m, data.today, width),
  })
  local meta = { { (m.group and "group" or "project") .. " milestone" } }
  if m.updated_at then
    local age = date.age(m.updated_at, data.now)
    table.insert(meta, { " · updated " .. (age == "now" and "just now" or (age .. " ago")) })
  end
  local where = m.project or m.group or data.project
  return body, header.border_title(width, header.crumb(where, "milestones"), "%" .. tostring(m.id), meta)
end

--- The sidebar: progress, work item counts, the issues in progress.
---@param data gg.ui.MilestoneDetailData
---@param width integer
---@return gg.ui.Doc
function M.sidebar(data, width)
  local inner = sidebar.inner(width)
  if data.issues.status ~= "ready" then
    local msg = data.issues.status == "error" and { data.issues.error or "failed", "GitlabDetailError" } or { "Loading…", "GitlabDetailMuted" }
    return sidebar.build({ { label = "Progress", lines = { { { text.truncate(msg[1], inner), msg[2] } } } } }, width)
  end
  local c = M.counts(data.issues.value)
  local n = math.max(1, math.min(math.floor((inner + 1) / 2), c.total))
  local fields = {
    {
      label = "Progress",
      lines = {
        progress.buckets(c.done, c.doing, c.todo, n),
        { { ("%d/%d closed"):format(c.done, c.total), "GitlabDetailMuted" } },
      },
    },
  }
  local items = {
    sidebar.spread({ { "○", "GitlabDetailAccent" }, { " To do" } }, { { tostring(c.todo), "GitlabDetailMuted" } }, inner),
    sidebar.spread({ { "◐", "GitlabProgressDoing" }, { " Doing" } }, { { tostring(c.doing), "GitlabDetailMuted" } }, inner),
    sidebar.spread({ { "✓", "GitlabProgressDone" }, { " Done" } }, { { tostring(c.done), "GitlabDetailMuted" } }, inner),
  }
  if c.unassigned > 0 then
    table.insert(items, sidebar.spread({ { "unassigned", "GitlabDetailMuted" } }, { { tostring(c.unassigned), "GitlabDueSoon" } }, inner))
  end
  table.insert(fields, { label = "Work items", lines = items })
  if #c.in_progress > 0 then
    table.insert(fields, { divider = true })
    local lines = {}
    for _, i in ipairs(c.in_progress) do
      table.insert(lines, { { "#" .. i.iid, "GitlabIid" }, { " " .. text.clean(i.title), "GitlabDetailValue" } })
    end
    table.insert(fields, { label = "In progress", lines = lines })
  end
  return sidebar.build(fields, width)
end

return M
