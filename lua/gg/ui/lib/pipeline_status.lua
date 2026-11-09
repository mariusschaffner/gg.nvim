--- Pipeline and stage statuses for the UI: the icon of every GitLab status,
--- the stage cell (one icon per stage) and the status cell (icon + word).
--- Shared by the merge requests and the pipelines tables. Pure; the cell
--- functions return segments `{ text, hl }` (see `gg.ui.Line:segments`).
local text = require("gg.ui.lib.text")

local M = {}

M.PLACEHOLDER = "·"
M.EMPTY = "—"
M.MAX_STAGES = 4
M.WARNING = "!"

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

-- the word shown in a status cell, by GitLab status
local WORDS = {
  success = "passed",
  failed = "failed",
  running = "running",
  pending = "pending",
  created = "pending",
  preparing = "pending",
  waiting_for_resource = "pending",
  waiting_for_callback = "pending",
  manual = "waiting",
  scheduled = "scheduled",
  canceled = "canceled",
  cancelled = "canceled",
  canceling = "canceling",
  skipped = "skipped",
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

--- The word a status cell shows: "passed", "waiting" (manual), "pending"
--- (created, preparing, ...); an unknown status is shown as it is.
---@param status string|nil
---@return string
function M.word(status)
  status = type(status) == "string" and status:lower() or ""
  if WORDS[status] then
    return WORDS[status]
  end
  if status:match("^success") then
    return "passed"
  end
  return status ~= "" and status or "unknown"
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

--- The stages cell: one icon per stage, space separated; more than
--- MAX_STAGES: the first three and "…". "—" without a pipeline.
---@param pipeline gg.Pipeline|nil
---@param st? gg.ui.CellState
---@return gg.ui.Segment[]
function M.stages(pipeline, st)
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

--- The status cell: icon and word in the status colour ("✓ passed"); a
--- passed pipeline with warnings (allowed failures) gets a trailing "!".
---@param status string|nil
---@param warnings? boolean
---@return gg.ui.Segment[]
function M.status_cell(status, warnings)
  local icon, hl = M.icon(status)
  local out = { { icon .. " " .. M.word(status), hl } }
  if warnings and M.icon_class(status) == "success" then
    table.insert(out, { " ", nil })
    table.insert(out, { M.WARNING, "DiagnosticWarn" })
  end
  return out
end

return M
