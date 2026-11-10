--- The issue detail view's header and sidebar. Pure.
---
---  ╭ infra / ops › issues › #17 ─────────── opened by Ann · updated 2h ago ╮
---  │  ● Open  Rotate Terraform state credentials #17                        │
---  │                                                                        │
---  │   WF:Doing   docs   ◆ 2026.11 Patch cycle  │  ● ● ○ 2/3 criteria      │
---  ╰────────────────────────────────────────────────────────────────────────╯
local avatar = require("gg.ui.lib.avatar")
local chip = require("gg.ui.lib.chip")
local date = require("gg.ui.lib.date")
local header = require("gg.ui.detail.header")
local markdown = require("gg.ui.lib.markdown")
local progress = require("gg.ui.lib.progress")
local sidebar = require("gg.ui.detail.sidebar")
local text = require("gg.ui.lib.text")

local M = {}

M.MILESTONE = "◆"
M.BRANCH = "⎇"

---@class gg.ui.Loadable<T> { status: "loading"|"ready"|"error", value?: T, error?: string }

--- The state pill of an issue.
---@param state string|nil
---@return { [1]: string, [2]: string }
function M.pill(state)
  if state == "closed" then
    return chip.pill("●", "Closed", "GitlabPillClosed")
  end
  return chip.pill("●", "Open", "GitlabPillOpened")
end

---@class gg.ui.IssueDetailData
---@field issue gg.Issue
---@field project string
---@field dates? gg.ui.Loadable
---@field branches? gg.ui.Loadable
---@field mrs? gg.ui.Loadable
---@field now integer epoch seconds
---@field chip_hl? gg.ui.ChipHl
---@field user_colors? table<string, string>
---@field me? string
---@field keys? table<string, string|nil> first key of each edit keymap (sidebar hints); nil: no hints
---@field editing? string the sidebar field being edited

--- The header: the body and the border title.
---@param data gg.ui.IssueDetailData
---@param width integer inner width of the header window
---@param narrow boolean no sidebar: add the meta strip
---@return gg.ui.Doc body
---@return gg.ui.Chunk[] title
function M.header(data, width, narrow)
  local issue = data.issue
  local chips = {}
  for i, l in ipairs(issue.labels or {}) do
    if i > 1 then
      table.insert(chips, { " ", nil })
    end
    table.insert(chips, chip.label(l, data.chip_hl))
  end
  if issue.milestone then
    if #chips > 0 then
      table.insert(chips, { "  ", nil })
    end
    table.insert(chips, { M.MILESTONE .. " " .. issue.milestone.title, "GitlabMilestoneRef" })
  end
  local done, total = markdown.tasks(issue.description)
  if total > 0 then
    if #chips > 0 then
      table.insert(chips, { "  │  ", "GitlabDetailDivider" })
    end
    vim.list_extend(chips, progress.dots(done, total))
    table.insert(chips, { (" %d/%d criteria"):format(done, total), "GitlabDetailMuted" })
  end
  local body = header.build({
    width = width,
    pill = M.pill(issue.state),
    title = issue.title or "",
    ref = "#" .. tostring(issue.iid),
    chips = chips,
    strip = narrow and M.strip(data) or nil,
  })
  local author = issue.author and (issue.author.name or issue.author.username) or "unknown"
  local meta = {}
  if issue.author then
    table.insert(meta, { "opened by " .. author })
  end
  if issue.updated_at then
    local age = date.age(issue.updated_at, data.now)
    table.insert(meta, { (#meta > 0 and " · " or "") .. "updated " .. (age == "now" and "just now" or (age .. " ago")) })
  end
  local title = header.border_title(width, header.crumb("issues"), "#" .. tostring(issue.iid), meta)
  return body, title
end

--- The one-line summary shown in the header when there is no sidebar.
---@param data gg.ui.IssueDetailData
---@return string
function M.strip(data)
  local issue = data.issue
  local parts = { issue.state == "closed" and "Closed" or "Open" }
  local a = issue.assignees and issue.assignees[1]
  table.insert(parts, a and ("@" .. a.username) or "unassigned")
  if issue.labels and issue.labels[1] then
    table.insert(parts, issue.labels[1].name)
  end
  if issue.milestone then
    table.insert(parts, M.MILESTONE .. " " .. issue.milestone.title)
  end
  local due = M.dates(data).due
  table.insert(parts, "due " .. (due or "-"))
  local b = data.branches and data.branches.status == "ready" and data.branches.value[1]
  table.insert(parts, b and b.name or "no branch")
  return table.concat(parts, " · ")
end

--- The start and due dates: from the work item when loaded, else the due
--- date of the issue.
---@param data gg.ui.IssueDetailData
---@return { start: string|nil, due: string|nil }
function M.dates(data)
  local d = data.dates
  if d and d.status == "ready" and d.value then
    return { start = d.value.start_date, due = d.value.due_date }
  end
  return { start = nil, due = data.issue.due_date }
end

local function loadable_lines(l, inner, fn)
  if not l or l.status == "loading" then
    return { { { "Loading…", "GitlabDetailMuted" } } }
  elseif l.status == "error" then
    return { { { text.truncate(l.error or "failed", inner), "GitlabDetailError" } } }
  end
  return fn(l.value)
end

--- A date label with its key: "START [gs]" (orange while edited).
---@param label string
---@param key string|nil|false
---@param editing boolean
---@return gg.Segs
function M.date_label(label, key, editing)
  local segs = { { label, editing and "GitlabDetailLabelEditing" or "GitlabDetailLabel" } }
  if key then
    table.insert(segs, { " [" .. key .. "]", "GitlabHintKey" })
  end
  return segs
end

local MR_HL = { merged = "GitlabDetailPositive", closed = "GitlabDetailError", locked = "GitlabDetailError" }

--- The sidebar.
---@param data gg.ui.IssueDetailData
---@param width integer inner width of the sidebar window
---@return gg.ui.Doc
function M.sidebar(data, width)
  local issue = data.issue
  local inner = sidebar.inner(width)
  local keys = data.keys or {}
  local open = issue.state ~= "closed"
  local assignees = {}
  for _, u in ipairs(issue.assignees or {}) do
    table.insert(assignees, avatar.segments(u, { overrides = data.user_colors, me = data.me }))
  end
  local labels = chip.wrap(issue.labels or {}, inner, data.chip_hl)
  local milestone = issue.milestone and { { { M.MILESTONE .. " " .. issue.milestone.title, "GitlabMilestoneRef" } } } or {}

  local dates
  if data.dates and data.dates.status == "loading" then
    dates = { { { "Loading…", "GitlabDetailMuted" } } }
  else
    local d = M.dates(data)
    if not d.start and not d.due then
      dates = {}
    else
      dates = {
        sidebar.spread({ { d.start or "?", d.start and "GitlabDetailDate" or "GitlabDetailMuted" } }, { { d.due or "?", d.due and "GitlabDetailDate" or "GitlabDetailMuted" } }, inner),
      }
    end
  end

  local dev = {}
  local loading = (not data.branches or data.branches.status == "loading") or (not data.mrs or data.mrs.status == "loading")
  if loading then
    dev = { { { "Loading…", "GitlabDetailMuted" } } }
  else
    vim.list_extend(dev, loadable_lines(data.branches, inner, function(list)
      return vim.tbl_map(function(b)
        return { { M.BRANCH .. " " .. b.name, "GitlabBranchSource" } }
      end, list)
    end))
    vim.list_extend(dev, loadable_lines(data.mrs, inner, function(list)
      return vim.tbl_map(function(mr)
        return { { "!" .. mr.iid, "GitlabDetailMuted" }, { " " .. (mr.title or ""), MR_HL[mr.state] or "GitlabDetailValue" } }
      end, list)
    end))
  end

  return sidebar.build({
    { label = "Assignee", lines = assignees, empty = "unassigned", id = "assignees", hint = open and keys.edit_assignees, editing = data.editing == "assignees" },
    { label = "Labels", lines = labels, empty = "no labels", id = "labels", hint = keys.edit_labels, editing = data.editing == "labels" },
    { label = "Milestone", lines = milestone, empty = "no milestone", id = "milestone", hint = open and keys.edit_milestone, editing = data.editing == "milestone" },
    {
      lines = dates,
      empty = "not scheduled",
      ids = { "start_date", "due_date" },
      label_segs = M.date_label("START", open and keys.edit_start_date, data.editing == "start_date"),
      right_segs = M.date_label("DUE", open and keys.edit_due_date, data.editing == "due_date"),
    },
    { divider = true },
    { label = "Development", lines = dev, empty = "no branch or merge request" },
  }, width)
end

return M
