--- Cell contents of the merge requests table: pipeline stage icons and the
--- diff column (numbers + bar). Pure; every function returns segments
--- `{ text, hl }` the renderer appends.
local text = require("gg.ui.lib.text")

local M = {}

M.PLACEHOLDER = "·"
M.EMPTY = "—"
M.MINUS = "−" -- U+2212
M.BAR = "█"
M.BAR_CELLS = 8
M.NUMBER_CELLS = 5
M.MAX_STAGES = 4

---@alias gg.ui.Segment { [1]: string, [2]: string|nil }

local ICONS = {
  success = { "✓", "GitlabPipelineSuccess" },
  failed = { "✗", "GitlabPipelineFailed" },
  running = { "◐", "GitlabPipelineRunning" },
  pending = { "○", "GitlabPipelinePending" },
  manual = { "▸", "GitlabPipelineManual" },
  canceled = { "⊘", "GitlabPipelineCanceled" },
  skipped = { "–", "GitlabPipelineSkipped" },
}

-- GitLab statuses that share an icon
local ALIASES = {
  created = "pending",
  waiting_for_resource = "pending",
  preparing = "pending",
  waiting_for_callback = "pending",
  scheduled = "pending",
  canceling = "canceled",
  cancelled = "canceled",
}

--- The icon class of a GitLab status ("success", "failed", ... "pending").
---@param status string|nil
---@return string
function M.icon_class(status)
  status = type(status) == "string" and status:lower() or ""
  if ICONS[status] then
    return status
  end
  if ALIASES[status] then
    return ALIASES[status]
  end
  if status:match("^success") then -- e.g. success_with_warnings
    return "success"
  end
  return "pending"
end

--- Icon and highlight of a status.
---@param status string|nil
---@return string icon
---@return string hl
function M.icon(status)
  local i = ICONS[M.icon_class(status)]
  return i[1], i[2]
end

--- A stage status from its jobs' statuses (when the API has no stage
--- status): any failed -> failed, else any running -> running, else any
--- manual -> manual, else all success -> success, otherwise pending.
---@param jobs { status: string|nil }[]
---@return string
function M.derive_stage_status(jobs)
  local has = {}
  local all_success = #jobs > 0
  for _, j in ipairs(jobs) do
    local c = M.icon_class(j.status)
    has[c] = true
    if c ~= "success" then
      all_success = false
    end
  end
  if has.failed then
    return "failed"
  elseif has.running then
    return "running"
  elseif has.manual then
    return "manual"
  elseif all_success then
    return "success"
  end
  return "pending"
end

--- The status of a stage: its own, else derived from its jobs.
---@param stage gg.PipelineStage
---@return string
function M.stage_status(stage)
  if stage.status then
    return stage.status
  end
  return M.derive_stage_status(stage.jobs or {})
end

---@class gg.ui.CellState
---@field loading? boolean not fetched yet
---@field failed? boolean GitLab reported an error

--- The pipeline cell: one icon per stage, space separated; more than
--- MAX_STAGES: the first three and "…". "—" without a pipeline.
---@param pipeline gg.Pipeline|nil
---@param st? gg.ui.CellState
---@return gg.ui.Segment[]
function M.pipeline(pipeline, st)
  if st and (st.loading or st.failed) then
    return { { M.PLACEHOLDER, "Comment" } }
  end
  if not pipeline then
    return { { M.EMPTY, "GitlabEmpty" } }
  end
  local stages = pipeline.stages or {}
  if #stages == 0 then
    -- a pipeline without stage data: its overall status
    local icon, hl = M.icon(pipeline.status)
    return { { icon, hl } }
  end
  local out = {}
  local shown = #stages > M.MAX_STAGES and M.MAX_STAGES - 1 or #stages
  for i = 1, shown do
    if i > 1 then
      table.insert(out, { " ", nil })
    end
    local icon, hl = M.icon(M.stage_status(stages[i]))
    table.insert(out, { icon, hl })
  end
  if shown < #stages then
    table.insert(out, { " ", nil })
    table.insert(out, { text.ELLIPSIS, "Comment" })
  end
  return out
end

--- A count in at most 4 characters: 9999, then 12k, 123k, 1M.
---@param n integer
---@return string
function M.compact(n)
  n = math.max(0, math.floor(n or 0))
  if n <= 9999 then
    return tostring(n)
  end
  if n < 1000000 then
    return math.floor(n / 1000) .. "k"
  end
  return math.min(999, math.floor(n / 1000000)) .. "M"
end

--- Green cells of the bar: round(add / (add + del) * cells), at least one
--- per non-zero side.
---@param add integer
---@param del integer
---@param cells? integer default BAR_CELLS
---@return integer green
function M.bar_split(add, del, cells)
  cells = cells or M.BAR_CELLS
  local total = add + del
  if total <= 0 then
    return 0
  end
  local green = math.floor(add / total * cells + 0.5)
  if add > 0 then
    green = math.max(1, green)
  end
  if del > 0 then
    green = math.min(cells - 1, green)
  end
  return green
end

local function right(s, width)
  local w = text.width(s)
  return w < width and string.rep(" ", width - w) .. s or s
end

--- The diff cell: "+add" and "−del" right-aligned in fixed slots, then the
--- bar when `with_bar`. `·` placeholders while loading, on an error, and in
--- the bar when both counts are 0.
---@param stats gg.DiffStatsSummary|nil
---@param st? gg.ui.CellState
---@param with_bar boolean
---@return gg.ui.Segment[]
function M.diff(stats, st, with_bar)
  local n = M.NUMBER_CELLS
  local out = {}
  if not stats or (st and (st.loading or st.failed)) then
    table.insert(out, { right(M.PLACEHOLDER, n), "Comment" })
    table.insert(out, { " ", nil })
    table.insert(out, { right(M.PLACEHOLDER, n), "Comment" })
    if with_bar then
      table.insert(out, { " ", nil })
      table.insert(out, { string.rep(M.PLACEHOLDER, M.BAR_CELLS), "Comment" })
    end
    return out
  end
  local add, del = stats.additions or 0, stats.deletions or 0
  table.insert(out, { right("+" .. M.compact(add), n), "GitlabDiffAdd" })
  table.insert(out, { " ", nil })
  table.insert(out, { right(M.MINUS .. M.compact(del), n), "GitlabDiffDelete" })
  if with_bar then
    table.insert(out, { " ", nil })
    if add + del == 0 then
      table.insert(out, { string.rep(M.PLACEHOLDER, M.BAR_CELLS), "Comment" })
    else
      local green = M.bar_split(add, del)
      table.insert(out, { string.rep(M.BAR, green), "GitlabDiffAdd" })
      table.insert(out, { string.rep(M.BAR, M.BAR_CELLS - green), "GitlabDiffDelete" })
    end
  end
  return out
end

return M
