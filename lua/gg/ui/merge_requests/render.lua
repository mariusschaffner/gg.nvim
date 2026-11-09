--- Render the merge requests table into lines, highlights and row metadata.
--- Pure.
---
--- One line per merge request. Static content only: the cursor mark and row highlight are overlays the
--- picker draws from `rows[*].mark_col`. Pipeline and diff cells show "·"
--- until their summary has loaded.
local cells = require("gg.ui.merge_requests.cells")
local columns = require("gg.ui.merge_requests.columns")
local grid = require("gg.ui.components.grid")
local line = require("gg.ui.lib.line")
local pipeline_status = require("gg.ui.lib.pipeline_status")
local text = require("gg.ui.lib.text")
local user_hl = require("gg.ui.lib.user_hl")

local M = {}

M.DRAFT = "[Draft] "
M.EMPTY = "—"

local TABS = {
  { key = "opened", label = "Open" },
  { key = "merged", label = "Merged" },
  { key = "closed", label = "Closed" },
  { key = "all", label = "All" },
}

---@class gg.ui.MrSummaryEntry
---@field summary? gg.MergeRequestSummary
---@field error? boolean the request failed
---@field diff? { additions: integer, deletions: integer } counts from the fallback (replace the summary's)
---@field diff_loading? boolean the fallback is still running
---@field diff_error? boolean the fallback failed

---@class gg.ui.MrRenderInput
---@field width integer window width in cells
---@field status "loading"|"ready"|"error"
---@field tab gg.ui.MrTab
---@field model? gg.ui.MrModel nil before the first load
---@field page? gg.ui.MrPage
---@field error? string
---@field loaded? integer
---@field truncated? integer the fetch limit, when it was hit
---@field pending? table<string, boolean> states still loading
---@field retry_key? string|false
---@field summaries? table<integer, gg.ui.MrSummaryEntry> by IID; absent = still loading
---@field user_colors? table<string, string>
---@field me? string the signed-in user's username (bold)

---@class gg.ui.MrRowInfo
---@field kind "tabs"|"blank"|"header"|"rule"|"mr"|"message"
---@field mr? gg.MergeRequest
---@field mark_col? integer byte column of the 2-cell cursor-mark slot

local function header_line(cols)
  return grid.header_line({
    { cols.iid, "!" },
    { cols.title, "Title" },
    { cols.source, "Source" },
    { cols.target, "Target" },
    { cols.reviewers, "Reviewers" },
    { cols.assignee, "Assignee" },
    { cols.pipeline, "Pipeline" },
    { cols.diff, "Diff" },
  })
end

local function title_cell(l, mr, width)
  local start = l.cells
  if mr.draft then
    local d = text.truncate(M.DRAFT, width)
    l:add(d, "GitlabDraft")
  end
  local room = start + width - l.cells
  if room > 0 then
    l:add(text.truncate(text.clean(mr.title), room))
  end
  l:pad_to(start + width)
end

local function users_cell(l, users, width, input)
  if #users == 0 then
    l:cell(M.EMPTY, width, "GitlabEmpty")
    return
  end
  local items = {}
  for _, u in ipairs(users) do
    table.insert(items, user_hl.item(text.clean(u.username), input.user_colors, input.me))
  end
  l:items(items, width)
end

local function assignee_cell(l, users, width, input)
  if #users == 0 then
    l:cell("unassigned", width, "GitlabUnassigned")
    return
  end
  local items = { user_hl.item(text.clean(users[1].username), input.user_colors, input.me) }
  if #users > 1 then
    table.insert(items, { "+" .. (#users - 1), "Comment" })
  end
  l:items(items, width)
end

local function mr_line(mr, cols, input)
  local l = line.new()
  l:pad_to(cols.mark.col)
  local mark_col = l.bytes
  l:add(string.rep(" ", cols.mark.width))
  l:cell("!" .. tostring(mr.iid), cols.iid.width, "GitlabIid")
  title_cell(l, mr, cols.title.width)
  if cols.source then
    l:pad_to(cols.source.col)
    l:cell(text.clean(mr.source_branch), cols.source.width, "GitlabBranchSource")
  end
  if cols.target then
    l:pad_to(cols.target.col)
    l:cell(text.clean(mr.target_branch), cols.target.width, "GitlabBranchTarget")
  end
  if cols.reviewers then
    l:pad_to(cols.reviewers.col)
    users_cell(l, mr.reviewers or {}, cols.reviewers.width, input)
  end
  l:pad_to(cols.assignee.col)
  assignee_cell(l, mr.assignees or {}, cols.assignee.width, input)

  local entry = input.summaries and input.summaries[mr.iid]
  local summary = entry and entry.summary
  local failed = summary and summary.failed or {}
  l:pad_to(cols.pipeline.col)
  l:segments(pipeline_status.stages(summary and summary.head_pipeline, {
    loading = entry == nil,
    failed = (entry and entry.error) or failed.head_pipeline,
  }), cols.pipeline.width)
  l:pad_to(cols.diff.col)
  l:segments(cells.diff(entry and entry.diff or (summary and summary.diff_stats), {
    loading = entry == nil or entry.diff_loading,
    failed = (entry and (entry.error or entry.diff_error)) or failed.diff_stats or (entry ~= nil and summary == nil),
  }, cols.diff.width >= columns.DIFF), cols.diff.width)
  return l, mark_col
end

--- Render the table.
---@param input gg.ui.MrRenderInput
---@return gg.ui.Rendered
function M.render(input)
  local cols = columns.layout(input.width)
  local out = grid.new(cols)
  grid.head(out, grid.tabs_line({
    tabs = TABS,
    active = input.tab,
    counts = input.model and input.model.counts or nil,
    pending = input.pending,
    truncated = input.truncated,
  }), header_line(cols))

  local page = input.page
  if grid.state(out, {
    status = input.status,
    noun = "merge requests",
    col = cols.iid.col,
    has_model = input.model ~= nil,
    empty = not page or #page.rows == 0,
    pending = grid.tab_pending(input.pending, input.tab),
    error = input.error,
    retry_key = input.retry_key,
    loaded = input.loaded,
  }) then
    return out
  end
  for _, mr in ipairs(page.rows) do
    local l, mark_col = mr_line(mr, cols, input)
    local lnum = grid.push(out, l, { kind = "mr", mr = mr, mark_col = mark_col })
    table.insert(out.selectable, lnum)
  end
  return out
end

return M
