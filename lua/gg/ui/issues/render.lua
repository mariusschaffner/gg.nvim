--- Render the issues table into lines, highlights and row metadata. Pure.
---
--- Static content only. The cursor mark, the active milestone edge and the
--- row highlight are overlays drawn by the view from `rows[*].mark_col` and
--- `rows[*].edge`, so moving the cursor never re-renders.
local columns = require("gg.ui.issues.columns")
local line = require("gg.ui.lib.line")
local tabs = require("gg.ui.components.tabs")
local text = require("gg.ui.lib.text")

local M = {}

M.HEADER_LINES = 4 -- tabs, blank, column header, rule
M.TABS_INDENT = 2
M.TABS_PAD = 2
M.MIN_BLOCK_LINES = 4 -- a milestone block is at least this tall
M.BAR_CELLS = 10

M.EDGE = "▎"
M.CURSOR_MARK = "▌"
M.EMPTY = "—"
M.RULE = "─"
M.DONE = "━"
M.TODO = "━" -- same glyph; GitlabProgressDone / Todo tell them apart

local TAB_LABELS = { opened = "Open", closed = "Closed", all = "All" }
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

---@class gg.ui.Rendered
---@field lines string[]
---@field marks gg.ui.Mark[] 0-based rows, byte columns
---@field virt_lines { row: integer, chunks: gg.ui.Chunk[] }[] 0-based row the lines go below
---@field rows gg.ui.RowInfo[] indexed by 1-based line number
---@field blocks gg.ui.RenderedBlock[]
---@field selectable integer[] 1-based line numbers of issue lines
---@field columns gg.ui.Columns

local function new_out(cols)
  return { lines = {}, marks = {}, virt_lines = {}, rows = {}, blocks = {}, selectable = {}, columns = cols }
end

local function push(out, l, info)
  local s, marks = l:result()
  table.insert(out.lines, s)
  local row = #out.lines - 1
  for _, m in ipairs(marks) do
    table.insert(out.marks, { row = row, col = m.col, end_col = m.end_col, hl = m.hl })
  end
  out.rows[#out.lines] = info
  return #out.lines
end

local function tabs_line(input)
  local counts = input.model and input.model.counts or nil
  local items = {}
  for _, key in ipairs({ "opened", "closed", "all" }) do
    table.insert(items, { key = key, label = TAB_LABELS[key], count = counts and counts[key] or nil })
  end
  -- indented like the column header, with roomier tabs
  local l = line.new():add(text.rep(" ", M.TABS_INDENT))
  for _, seg in ipairs(tabs.segments(items, input.tab, { pad = M.TABS_PAD })) do
    l:add(seg[1], seg[2])
  end
  if input.truncated then
    l:add(("  (first %d)"):format(input.truncated), "Comment")
  end
  return l
end

local function header_line(cols)
  local l = line.new()
  local function at(col, label)
    l:pad_to(col.col)
    l:add(label, "GitlabColumnHeader")
  end
  at(cols.milestone, "Milestone")
  at(cols.iid, "Issue")
  if cols.labels then
    at(cols.labels, "Labels")
  end
  if cols.assignee then
    at(cols.assignee, "Assignee")
  end
  at(cols.state, "State")
  return l
end

local function labels_cell(l, labels, width, label_hl)
  local start = l.cells
  local used = 0
  for _, lab in ipairs(labels or {}) do
    local s = "~" .. text.clean(lab.name)
    local sep = used > 0 and 1 or 0
    local w = text.width(s)
    local hl = label_hl(lab.color)
    if used + sep + w <= width then
      if sep == 1 then
        l:add(" ")
      end
      l:add(s, hl)
      used = used + sep + w
    else
      local room = width - used - sep
      if room >= 1 then
        if sep == 1 then
          l:add(" ")
        end
        l:add(text.truncate(s, room), hl)
      end
      break
    end
  end
  l:pad_to(start + width)
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
local function issue_part(l, cols, issue, label_hl)
  l:pad_to(cols.mark.col)
  local mark_col = l.bytes
  l:add(string.rep(" ", cols.mark.width))
  l:cell("#" .. tostring(issue.iid), cols.iid.width, "GitlabIid")
  l:cell(text.clean(issue.title), cols.title.width)
  if cols.labels then
    l:pad_to(cols.labels.col)
    labels_cell(l, issue.labels, cols.labels.width, label_hl)
  end
  if cols.assignee then
    l:pad_to(cols.assignee.col)
    local s, hl = assignee_text(issue)
    l:cell(s, cols.assignee.width, hl)
  end
  l:pad_to(cols.state.col)
  if issue.state == "closed" then
    l:cell("✓ Closed", cols.state.width, "GitlabStateClosed")
  else
    l:cell("● Open", cols.state.width, "GitlabStateOpened")
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

local function separator(out, cols, row)
  table.insert(out.virt_lines, { row = row - 1, chunks = { { text.rep(M.RULE, cols.width), "GitlabSeparator" } } })
end

local function render_block(out, cols, block, bi, label_hl, next_block)
  local cell_text = cols.milestone.width - columns.GAP
  local first
  if block.kind == "top" then
    local issue = block.issues[1]
    local l = line.new()
    l:pad_to(cols.milestone.col)
    l:cell(M.EMPTY, cell_text, "GitlabEmpty")
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

local function message(out, cols, s, hl)
  local l = line.new()
  l:pad_to(cols.milestone.col)
  l:add(text.clean(s), hl)
  push(out, l, { kind = "message" })
end

--- Render the table.
---@param input gg.ui.RenderInput
---@return gg.ui.Rendered
function M.render(input)
  local cols = columns.layout(input.width)
  local out = new_out(cols)
  local label_hl = input.label_hl or function()
    return "GitlabLabelFallback"
  end

  push(out, tabs_line(input), { kind = "tabs" })
  push(out, line.new(), { kind = "blank" })
  push(out, header_line(cols), { kind = "header" })
  push(out, line.new():add(text.rep(M.RULE, cols.width), "GitlabSeparator"), { kind = "rule" })

  if input.status == "error" then
    message(out, cols, "Failed to load issues: " .. (input.error or "unknown error"), "DiagnosticError")
    if input.retry_key then
      local l = line.new()
      l:pad_to(cols.milestone.col)
      l:add("[" .. input.retry_key .. "]", "GitlabHintKey")
      l:add(" Retry", "GitlabHintText")
      push(out, l, { kind = "message" })
    end
    return out
  end
  if input.status == "loading" and not input.model then
    local s = "Loading issues…"
    if input.loaded and input.loaded > 0 then
      s = ("%s (%d)"):format(s, input.loaded)
    end
    message(out, cols, s, "Comment")
    return out
  end
  local page = input.page
  if not page or #page.blocks == 0 then
    message(out, cols, "No issues match", "Comment")
    return out
  end
  for bi, block in ipairs(page.blocks) do
    render_block(out, cols, block, bi, label_hl, page.blocks[bi + 1])
  end
  return out
end

return M
