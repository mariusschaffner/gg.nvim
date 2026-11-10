--- The pipeline graph: one column per stage, a 3-row pill per job,
--- connectors from stage to stage. Pure.
---
---   Build ✓ 1:02                       Test ◐ running
---   ╭──────────────────────────╮      ┏━━━━━━━━━━━━━━━━━━━━━━━━━━┓
---   │ ✓ build-agent       1:02 │───┬──┃ ◐ molecule          2:14 ┃
---   ╰──────────────────────────╯   │  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━┛
---                                  │  ╭╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╮
---                                  └──╎ ▶ deploy-prod     manual ╎
---                                     ╰╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╯
---
--- `needs:` edges are not drawn. Stages that do not fit are left out
--- behind "‹ n more" / "n more ›" markers; the window always shows the
--- selected stage, and job rows scroll to keep the selected job visible.
local canvas = require("gg.ui.lib.canvas")
local status = require("gg.ui.detail.pipeline.status")
local text = require("gg.ui.lib.text")

local M = {}

M.COL_W = 28
M.GAP = 6
M.MARKER_W = 9
M.JOB_H = 3

local SOLID = { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│" }
local DASHED = { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "╌", v = "╎" }
local THICK = { tl = "┏", tr = "┓", bl = "┗", br = "┛", h = "━", v = "┃" }

-- (up, down, left, right) -> junction
local JUNCTION = {
  ["0011"] = "─",
  ["1100"] = "│",
  ["0110"] = "┐",
  ["0101"] = "┌",
  ["1010"] = "┘",
  ["1001"] = "└",
  ["0111"] = "┬",
  ["1011"] = "┴",
  ["1110"] = "┤",
  ["1101"] = "├",
  ["1111"] = "┼",
  ["0010"] = "─",
  ["0001"] = "─",
  ["1000"] = "│",
  ["0100"] = "│",
}

--- The spine glyph for a connector row.
---@param up boolean
---@param down boolean
---@param left boolean
---@param right boolean
---@return string
function M.junction(up, down, left, right)
  local key = (up and "1" or "0") .. (down and "1" or "0") .. (left and "1" or "0") .. (right and "1" or "0")
  return JUNCTION[key] or " "
end

--- Which stages fit in `width`: all of them, or a window of them that
--- keeps `selected` visible (moving `start` as little as possible).
---@param n integer number of stages
---@param width integer
---@param selected integer
---@param start? integer the previous first visible stage
---@return integer first
---@return integer last
function M.viewport(n, width, selected, start)
  local full = n * M.COL_W + math.max(0, n - 1) * M.GAP
  if full <= width then
    return 1, n
  end
  local fit = math.max(1, math.floor((width - 2 * M.MARKER_W + M.GAP) / (M.COL_W + M.GAP)))
  local first = math.max(1, math.min(start or 1, n - fit + 1))
  if selected < first then
    first = selected
  elseif selected > first + fit - 1 then
    first = selected - fit + 1
  end
  return first, math.min(n, first + fit - 1)
end

--- The rows of a connector between `left_n` and `right_n` jobs: the middle
--- row of each job pill (0-based, below the stage header).
---@param left_n integer
---@param right_n integer
---@return { row: integer, glyph: string, left: boolean, right: boolean }[]
function M.connector(left_n, right_n)
  local function mid(j)
    return 1 + (j - 1) * M.JOB_H + 1
  end
  local rows = {}
  local lefts, rights = {}, {}
  for j = 1, left_n do
    lefts[mid(j)] = true
  end
  for j = 1, right_n do
    rights[mid(j)] = true
  end
  local top, bottom = mid(1), mid(math.max(left_n, right_n))
  for r = top, bottom do
    table.insert(rows, {
      row = r,
      glyph = M.junction(r > top, r < bottom, lefts[r] == true, rights[r] == true),
      left = lefts[r] == true,
      right = rights[r] == true,
    })
  end
  return rows
end

---@class gg.ui.GraphInput
---@field stages gg.PipelineStage[]
---@field width integer
---@field selected { stage: integer, job: integer }|nil
---@field focus boolean the graph has the keys (selected pill in the accent colour)
---@field now integer
---@field start? integer previous first visible stage
---@field max_rows? integer at most this many rows (job rows scroll)

--- Draw the graph.
---@param input gg.ui.GraphInput
---@return gg.ui.Doc doc
---@return integer start first visible stage (pass it back next time)
function M.render(input)
  local stages = vim.tbl_filter(function(st)
    return st.jobs and #st.jobs > 0
  end, input.stages or {})
  local width = math.max(M.COL_W + 2, input.width)
  if #stages == 0 then
    local c = canvas.new(width, 1)
    c:put(0, 1, "No jobs in this pipeline yet.", "GitlabDetailMuted")
    return c:doc(), 1
  end
  local sel = input.selected or { stage = 1, job = 1 }
  -- the selected stage among the non-empty ones
  local sel_stage = 1
  for i, st in ipairs(stages) do
    if st == input.stages[sel.stage] then
      sel_stage = i
    end
  end
  local first, last = M.viewport(#stages, width, sel_stage, input.start)
  local max_jobs = 0
  for i = first, last do
    max_jobs = math.max(max_jobs, #stages[i].jobs)
  end
  -- job rows that fit, scrolled to the selected job
  local fit_jobs = max_jobs
  if input.max_rows then
    fit_jobs = math.max(1, math.min(max_jobs, math.floor((input.max_rows - 1) / M.JOB_H)))
  end
  local job_off = 0
  if sel.job > fit_jobs then
    job_off = sel.job - fit_jobs
  end
  local height = 1 + M.JOB_H * fit_jobs
  local c = canvas.new(width, height)
  local x0 = 0
  if first > 1 then
    c:put(1 + M.JOB_H * 0, 0, text.truncate(("‹ %d more"):format(first - 1), M.MARKER_W - 1), "GitlabGraphMore")
    x0 = M.MARKER_W
  end
  local function col_of(i)
    return x0 + (i - first) * (M.COL_W + M.GAP)
  end
  for i = first, last do
    local st = stages[i]
    local x = col_of(i)
    -- header
    local cx = x
    for _, sg in ipairs(status.stage_summary(st, input.now)) do
      local s = text.truncate(sg[1], math.max(0, x + M.COL_W - cx))
      c:put(0, cx, s, sg[2])
      cx = cx + text.width(s)
    end
    -- jobs
    for j = 1 + job_off, math.min(#st.jobs, job_off + fit_jobs) do
      local job = st.jobs[j]
      local y = 1 + (j - 1 - job_off) * M.JOB_H
      local b = status.job_badge(job, input.now)
      local is_sel = i == sel_stage and j == sel.job
      local box = is_sel and THICK or (b.dashed and DASHED or SOLID)
      local border_hl = is_sel and (input.focus and "GitlabGraphSelected" or "GitlabDetailTitle") or (b.dashed and b.icon_hl or "GitlabGraphBorder")
      local inner = M.COL_W - 2
      c:put(y, x, box.tl .. string.rep(box.h, inner) .. box.tr, border_hl)
      c:put(y + 2, x, box.bl .. string.rep(box.h, inner) .. box.br, border_hl)
      c:put(y + 1, x, box.v, border_hl)
      c:put(y + 1, x + M.COL_W - 1, box.v, border_hl)
      -- the thick border marks the selection; no fill (a cell has one
      -- highlight, so a fill would only show between the texts)
      c:put(y + 1, x + 2, b.icon, b.icon_hl)
      local right = b.right or ""
      local name_room = inner - 4 - text.width(right) - 1
      c:put(y + 1, x + 4, text.truncate(text.clean(job.name), math.max(1, name_room)), is_sel and "GitlabDetailTitle" or b.name_hl)
      if right ~= "" then
        c:put(y + 1, x + M.COL_W - 2 - text.width(right), right, b.right_hl)
      end
    end
    -- connector to the next visible stage
    if i < last then
      local nxt = stages[i + 1]
      local gx = x + M.COL_W
      local ln = math.max(0, math.min(#st.jobs - job_off, fit_jobs))
      local rn = math.max(0, math.min(#nxt.jobs - job_off, fit_jobs))
      for _, r in ipairs(M.connector(ln, rn)) do
        if r.row < height then
          if r.left then
            c:put(r.row, gx, "───", "GitlabGraphBorder")
          end
          c:put(r.row, gx + 3, r.glyph, "GitlabGraphBorder")
          if r.right then
            c:put(r.row, gx + 4, "──", "GitlabGraphBorder")
          end
        end
      end
    end
  end
  if last < #stages then
    local s = ("%d more ›"):format(#stages - last)
    c:put(1, col_of(last) + M.COL_W + 1, text.truncate(s, M.MARKER_W - 1), "GitlabGraphMore")
  end
  return c:doc(" "), first
end

return M
