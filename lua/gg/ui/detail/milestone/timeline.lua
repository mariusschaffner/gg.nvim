--- The milestone's date strip: elapsed time from start to due with a
--- "today" marker, and the state pill. Pure: "today" is passed in.
---
---   │20.10.     │27.10.     │03.11.     │10.11.                 16.11.│
---   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┃──────────────────────────
---                                          today
local chip = require("gg.ui.lib.chip")
local date = require("gg.ui.lib.date")
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")
local text = require("gg.ui.lib.text")

local M = {}

M.TICK = "│"
M.DONE = "━"
M.TODO = "─"
M.MARKER = "┃"

---@alias gg.ui.BarState "no_dates"|"closed"|"before_start"|"overdue"|"in_progress"

--- The start of the strip: the start date, else (with a due date) the
--- creation date.
---@param m gg.Milestone|gg.MilestoneRef
---@return gg.ui.Date|nil start
---@return gg.ui.Date|nil due
function M.range(m)
  local due = date.parse(m.due_date)
  local start = date.parse(m.start_date)
  if not start and due then
    start = date.parse(m.created_at)
  end
  return start, due
end

--- The state of the strip and the days that go with it (until the start,
--- past the due date).
---@param m gg.Milestone|gg.MilestoneRef
---@param today gg.ui.Date
---@return gg.ui.BarState
---@return integer|nil days
function M.bar_state(m, today)
  local start, due = M.range(m)
  if not start or not due then
    return "no_dates", nil
  end
  if m.state == "closed" then
    return "closed", nil
  end
  if date.diff_days(today, start) > 0 then
    return "before_start", date.diff_days(today, start)
  end
  if date.diff_days(due, today) > 0 then
    return "overdue", date.diff_days(due, today)
  end
  return "in_progress", nil
end

--- The state pill: Closed, Upcoming (starts later), Overdue, Active.
---@param m gg.Milestone|gg.MilestoneRef
---@param today gg.ui.Date
---@return { [1]: string, [2]: string }
function M.pill(m, today)
  if m.state == "closed" then
    return chip.pill("●", "Closed", "GitlabPillClosed")
  end
  local start = date.parse(m.start_date)
  local due = date.parse(m.due_date)
  if start and date.diff_days(today, start) > 0 then
    return chip.pill("●", "Upcoming", "GitlabPillUpcoming")
  end
  if due and date.diff_days(due, today) > 0 then
    return chip.pill("●", "Overdue", "GitlabPillOverdue")
  end
  return chip.pill("●", "Active", "GitlabPillActive")
end

--- The column of `d` on a strip `width` cells wide from `start` to `due`.
---@param d gg.ui.Date
---@param start gg.ui.Date
---@param due gg.ui.Date
---@param width integer
---@return integer 0-based
function M.column(d, start, due, width)
  local total = date.diff_days(start, due) + 1
  local col = math.floor(date.diff_days(start, d) * width / math.max(1, total))
  return math.max(0, math.min(width - 1, col))
end

-- cells -> a line, merging runs of the same highlight
local function cells_line(cells)
  local l = line.new()
  local run, hl = {}, false
  local function flush()
    if #run > 0 then
      l:add(table.concat(run), hl or nil)
    end
    run = {}
  end
  for _, c in ipairs(cells) do
    if c[2] ~= hl then
      flush()
      hl = c[2]
    end
    table.insert(run, c[1])
  end
  flush()
  return l
end

-- `s` written into `cells` from column `col` (one cell per character)
local function put(cells, col, s, hl)
  local n = vim.fn.strchars(s)
  for i = 0, n - 1 do
    if cells[col + i + 1] then
      cells[col + i + 1] = { vim.fn.strcharpart(s, i, 1), hl }
    end
  end
end

--- The tick line: a tick at the start, every Monday in between and the
--- due date, each with its "DD.MM." label (labels that would collide are
--- dropped, the ticks stay).
---@param start gg.ui.Date
---@param due gg.ui.Date
---@param width integer
---@return gg.ui.Line
function M.ticks(start, due, width)
  local cells = {}
  for i = 1, width do
    cells[i] = { " ", nil }
  end
  local ticks = { { col = 0, label = date.dotted_short(start) } }
  local d = date.add_days(start, 1)
  while date.diff_days(d, due) > 0 do
    if date.weekday(d) == 1 then
      table.insert(ticks, { col = M.column(d, start, due, width), label = date.dotted_short(d) })
    end
    d = date.add_days(d, 1)
  end
  local due_label = date.dotted_short(due)
  local due_start = width - 1 - text.width(due_label)
  for i, t in ipairs(ticks) do
    put(cells, t.col, M.TICK, "GitlabStripMuted")
    local next_col = ticks[i + 1] and ticks[i + 1].col or due_start
    if t.col + text.width(t.label) + 1 < next_col or (not ticks[i + 1] and t.col + text.width(t.label) < due_start) then
      put(cells, t.col + 1, t.label, "GitlabStripMuted")
    end
  end
  if due_start > 0 then
    put(cells, due_start, due_label, "GitlabStripMuted")
  end
  put(cells, width - 1, M.TICK, "GitlabStripMuted")
  return cells_line(cells)
end

--- The strip (three lines, or one when the dates are missing).
---@param m gg.Milestone|gg.MilestoneRef
---@param today gg.ui.Date
---@param width integer
---@return gg.ui.Doc
function M.strip(m, today, width)
  local d = doc.new()
  local pad = " "
  width = math.max(12, width - 2)
  local state, days = M.bar_state(m, today)
  if state == "no_dates" then
    d:line(line.new():add(pad):add("no dates", "GitlabEmpty"))
    return d
  end
  local start, due = M.range(m)
  -- a cells line after the padding, its highlights shifted along
  local function emit(l)
    local str, marks = l:result()
    local row = d:line(line.new():add(pad):add(str)) - 1
    for _, mk in ipairs(marks) do
      table.insert(d.marks, { row = row, col = #pad + mk.col, end_col = #pad + mk.end_col, hl = mk.hl })
    end
  end
  emit(M.ticks(start, due, width))

  local bar = {}
  local marker = M.column(today, start, due, width)
  for i = 1, width do
    local col = i - 1
    if state == "in_progress" then
      if col < marker then
        bar[i] = { M.DONE, "GitlabTimelineBar" }
      elseif col == marker then
        bar[i] = { M.MARKER, "GitlabDetailTitle" }
      else
        bar[i] = { M.TODO, "GitlabStripRule" }
      end
    elseif state == "closed" then
      bar[i] = { M.DONE, "GitlabProgressTodo" }
    elseif state == "overdue" then
      bar[i] = { M.DONE, "GitlabTimelineOverdue" }
    else
      bar[i] = { M.TODO, "GitlabStripRule" }
    end
  end
  emit(cells_line(bar))

  local label
  if state == "in_progress" then
    label = "today"
    local col = math.max(0, math.min(width - text.width(label), marker - math.floor(text.width(label) / 2)))
    d:line(line.new():add(pad):add(string.rep(" ", col)):add(label, "GitlabDetailTitle"))
  else
    if state == "before_start" then
      label = ("starts in %d day%s"):format(days, days == 1 and "" or "s")
    elseif state == "overdue" then
      label = ("%d day%s overdue"):format(days, days == 1 and "" or "s")
    else
      label = "closed " .. date.dotted_short(due)
    end
    d:line(line.new():add(pad):add(label, state == "overdue" and "GitlabTimelineOverdue" or "GitlabDetailTitle"))
  end
  return d
end

return M
