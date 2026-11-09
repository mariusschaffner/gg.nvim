--- Render the issues table into lines, highlights and row metadata. Pure.
---
--- Static content only. The cursor mark, the active milestone edge and the
--- row highlight are overlays drawn by the view from `rows[*].mark_col` and
--- `rows[*].edge`, so moving the cursor never re-renders. The tabs line,
--- header, rule, separators and messages come from `gg.ui.components.grid`.
local columns = require("gg.ui.issues.columns")
local grid = require("gg.ui.components.grid")
local line = require("gg.ui.lib.line")
local text = require("gg.ui.lib.text")

local M = {}

M.HEADER_LINES = grid.HEADER_LINES -- tabs, blank, column header, rule
M.TABS_INDENT = 2
M.TABS_PAD = 2
M.MIN_BLOCK_LINES = 4 -- a milestone block is at least this tall
M.BAR_CELLS = 10

M.EDGE = "▎"
M.CURSOR_MARK = "▌"
M.EMPTY = "—"
M.RULE = grid.RULE
M.DONE = "━"
M.TODO = "━" -- same glyph; GitlabProgressDone / Todo tell them apart

local TABS = { { key = "opened", label = "Open" }, { key = "closed", label = "Closed" }, { key = "all", label = "All" } }
local TONE_HL = { normal = "GitlabDue", soon = "GitlabDueSoon", overdue = "GitlabDueOverdue", none = "GitlabEmpty" }

---@class gg.ui.RenderInput
---@field width integer window width in cells
---@field status "loading"|"ready"|"error"
---@field tab gg.ui.Tab
---@field model? gg.ui.IssuesModel nil before the first load
---@field page? gg.ui.Page the page to draw
---@field error? string message for the error state
---@field loaded? integer issues loaded so far (loading state)
---@field truncated? integer the fetch limit, when it was hit
---@field pending? { opened: boolean, closed: boolean } states still loading: their
---  tab counts get a "…" and an empty result says "Loading issues…"
---@field retry_key? string|false key shown as "[R] Retry"
---@field label_hl? fun(color: string|nil): string highlight group for a label colour

---@class gg.ui.RowInfo
---@field kind "tabs"|"blank"|"header"|"rule"|"issue"|"filler"|"message"
---@field block? integer index into `blocks`
---@field issue? gg.Issue
---@field mark_col? integer byte column of the 2-cell cursor-mark slot
---@field edge? { col: integer, end_col: integer } byte range of "▎"

---@class gg.ui.RenderedBlock
---@field first integer first line (1-based)
---@field last integer last line (1-based, filler lines included)
---@field kind "top"|"milestone"
---@field key string
---@field milestone? gg.ui.MilestoneInfo

local push = grid.push

--- True while issues of `tab` are still loading.
---@param pending? { opened: boolean, closed: boolean }
---@param tab gg.ui.Tab
---@return boolean
function M.tab_pending(pending, tab)
  return grid.tab_pending(pending, tab)
end

local function tabs_line(input)
  -- indented like the column header, with roomier tabs
  return grid.tabs_line({
    tabs = TABS,
    active = input.tab,
    counts = input.model and input.model.counts or nil,
    pending = input.pending,
    indent = M.TABS_INDENT,
    pad = M.TABS_PAD,
    truncated = input.truncated,
  })
end

local function header_line(cols)
  return grid.header_line({
    { cols.milestone, "Milestone" },
    { cols.iid, "Issue" },
    { cols.labels, "Labels" },
    { cols.assignee, "Assignee" },
    { cols.state, "State" },
  })
end

local function labels_cell(l, labels, width, label_hl)
  local items = {}
  for _, lab in ipairs(labels or {}) do
    table.insert(items, { "~" .. text.clean(lab.name), label_hl(lab.color) })
  end
  l:items(items, width)
end

local function assignee_text(issue)
  local users = issue.assignees or {}
  if #users == 0 then
    return "unassigned", "GitlabUnassigned"
  end
  local s = "@" .. text.clean(users[1].username)
  if #users > 1 then
    s = s .. " +" .. (#users - 1)
  end
  return s, nil
end

--- The issue part of a body line: mark slot, IID, title, labels, assignee, state.
--- Unassigned issues are drawn dimmed (`GitlabUnassigned`) from the IID on.
local function issue_part(l, cols, issue, label_hl)
  local dim = #(issue.assignees or {}) == 0 and "GitlabUnassigned" or nil
  l:pad_to(cols.mark.col)
  local mark_col = l.bytes
  l:add(string.rep(" ", cols.mark.width))
  l:cell("#" .. tostring(issue.iid), cols.iid.width, dim or "GitlabIid")
  l:cell(text.clean(issue.title), cols.title.width, dim or "GitlabIssueTitle")
  if cols.labels then
    l:pad_to(cols.labels.col)
    labels_cell(l, issue.labels, cols.labels.width, dim and function()
      return dim
    end or label_hl)
  end
  if cols.assignee then
    l:pad_to(cols.assignee.col)
    local s, hl = assignee_text(issue)
    l:cell(s, cols.assignee.width, hl)
  end
  l:pad_to(cols.state.col)
  if issue.state == "closed" then
    l:cell("✓ Closed", cols.state.width, dim or "GitlabStateClosed")
  else
    l:cell("● Open", cols.state.width, dim or "GitlabStateOpened")
  end
  return mark_col
end

--- Progress bar cells: round(closed / total * 10), halves round up.
---@param closed integer
---@param total integer
---@return integer
function M.bar_cells(closed, total)
  if not total or total <= 0 then
    return 0
  end
  local n = math.floor(closed / total * M.BAR_CELLS + 0.5)
  return math.max(0, math.min(M.BAR_CELLS, n))
end

-- line `i` (1..3) of the milestone cell; anything after is blank
local function milestone_cell(l, info, i, width)
  if i == 1 then
    local name = text.truncate(text.clean(info.name), width)
    l:add(name, "GitlabMilestoneName")
    local room = width - text.width(name)
    if info.rest ~= "" and room >= 2 then
      l:add(" ")
      l:add(text.truncate(text.clean(info.rest), room - 1), "GitlabMilestoneTitle")
    end
  elseif i == 2 then
    l:add(text.truncate(info.due.text, width), TONE_HL[info.due.tone] or "GitlabDue")
  elseif i == 3 then
    local p = info.progress
    local on = M.bar_cells(p.closed, p.total)
    local bar = math.min(M.BAR_CELLS, width)
    on = math.min(on, bar)
    l:add(string.rep(M.DONE, on), "GitlabProgressDone")
    l:add(string.rep(M.TODO, bar - on), "GitlabProgressTodo")
    local count = (" %d/%d"):format(p.closed, p.total)
    l:add(text.truncate(count, width - bar), "GitlabProgressText")
  end
end

local function separator(out, _, row)
  grid.separator(out, row)
end

local function render_block(out, cols, block, bi, label_hl, next_block)
  local cell_text = cols.milestone and (cols.milestone.width - columns.GAP) or 0
  local first
  if block.kind == "top" then
    local issue = block.issues[1]
    local l = line.new()
    if cols.milestone then
      l:pad_to(cols.milestone.col)
      l:cell(M.EMPTY, cell_text, "GitlabEmpty")
    end
    local mark_col = issue_part(l, cols, issue, label_hl)
    first = push(out, l, { kind = "issue", block = bi, issue = issue, mark_col = mark_col })
    table.insert(out.selectable, first)
    table.insert(out.blocks, { first = first, last = first, kind = "top", key = block.key })
    -- top-level issues sit together; one rule after the last of them
    if not (next_block and next_block.kind == "top") then
      separator(out, cols, first)
    end
    return
  end
  local n = math.max(#block.issues, M.MIN_BLOCK_LINES)
  local last
  for i = 1, n do
    local l = line.new()
    l:add(M.EDGE, "GitlabMilestoneEdge")
    local edge = { col = 0, end_col = #M.EDGE }
    l:pad_to(cols.milestone.col)
    local start = l.cells
    milestone_cell(l, block.milestone, i, cell_text)
    l:pad_to(start + cols.milestone.width)
    local issue = block.issues[i]
    local row
    if issue then
      local mark_col = issue_part(l, cols, issue, label_hl)
      row = push(out, l, { kind = "issue", block = bi, issue = issue, mark_col = mark_col, edge = edge })
      table.insert(out.selectable, row)
    else
      row = push(out, l, { kind = "filler", block = bi, edge = edge })
    end
    first = first or row
    last = row
  end
  table.insert(out.blocks, { first = first, last = last, kind = "milestone", key = block.key, milestone = block.milestone })
  separator(out, cols, last)
end

--- Render the table.
---@param input gg.ui.RenderInput
---@return gg.ui.Rendered
function M.render(input)
  -- no issue has a milestone: no Milestone column
  local cols = columns.layout(input.width, { milestones = not input.model or input.model.has_milestones ~= false })
  local out = grid.new(cols)
  local label_hl = input.label_hl or function()
    return "GitlabLabelFallback"
  end

  grid.head(out, tabs_line(input), header_line(cols))

  local page = input.page
  if grid.state(out, {
    status = input.status,
    noun = "issues",
    col = (cols.milestone or cols.mark).col,
    has_model = input.model ~= nil,
    empty = not page or #page.blocks == 0,
    pending = M.tab_pending(input.pending, input.tab),
    error = input.error,
    retry_key = input.retry_key,
    loaded = input.loaded,
  }) then
    return out
  end
  for bi, block in ipairs(page.blocks) do
    render_block(out, cols, block, bi, label_hl, page.blocks[bi + 1])
  end
  return out
end

return M
