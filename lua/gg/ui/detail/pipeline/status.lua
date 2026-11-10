--- Pipeline and job statuses in the pipeline detail view: pills, job
--- badges, stage summaries and running clocks. Pure.
local chip = require("gg.ui.lib.chip")
local date = require("gg.ui.lib.date")

local M = {}

local ACTIVE = {
  created = true,
  waiting_for_resource = true,
  waiting_for_callback = true,
  preparing = true,
  pending = true,
  running = true,
  canceling = true,
  scheduled = true,
}

local function norm(s)
  return type(s) == "string" and s:lower() or ""
end

--- True while a pipeline or job can still change.
---@param status string|nil
---@return boolean
function M.is_active(status)
  return ACTIVE[norm(status)] == true
end

--- The pipeline's state pill.
---@param status string|nil
---@return { [1]: string, [2]: string }
function M.pill(status)
  local s = norm(status)
  if s == "running" or s == "canceling" then
    return chip.pill("◐", "Running", "GitlabPillRunning")
  elseif s == "success" then
    return chip.pill("✓", "Passed", "GitlabPillPassed")
  elseif s == "failed" then
    return chip.pill("✗", "Failed", "GitlabPillFailed")
  elseif s == "canceled" or s == "cancelled" or s == "skipped" then
    return chip.pill("⊘", "Canceled", "GitlabPillCanceled")
  elseif s == "manual" then
    return chip.pill("▶", "Manual", "GitlabPillManual")
  end
  return chip.pill("◷", "Pending", "GitlabPillPending")
end

--- Seconds a job or pipeline has run: its duration, or (while running)
--- the time since it started.
---@param item { status?: string, duration?: number, started_at?: string, finished_at?: string }
---@param now integer
---@return number|nil
function M.elapsed(item, now)
  local s = norm(item.status)
  if s == "running" or s == "canceling" then
    local start = date.parse_time(item.started_at)
    if start then
      return math.max(0, now - start)
    end
  end
  if item.duration then
    return item.duration
  end
  local a, b = date.parse_time(item.started_at), date.parse_time(item.finished_at)
  if a and b then
    return math.max(0, b - a)
  end
  return nil
end

---@class gg.ui.JobBadge
---@field icon string
---@field icon_hl string
---@field name_hl string
---@field dashed boolean manual jobs
---@field right string duration or a word
---@field right_hl string

--- How a job is drawn in the graph.
---@param job gg.Job
---@param now integer
---@return gg.ui.JobBadge
function M.job_badge(job, now)
  local s = norm(job.status)
  local clock = date.clock(M.elapsed(job, now))
  local b = { icon = "?", icon_hl = "GitlabDetailMuted", name_hl = "GitlabDetailValue", dashed = false, right = clock, right_hl = "GitlabDetailMuted" }
  if s == "success" then
    b.icon, b.icon_hl = "✓", "GitlabPipelineSuccess"
  elseif s == "running" or s == "canceling" then
    b.icon, b.icon_hl, b.right_hl = "◐", "GitlabPipelineRunning", "GitlabPipelineRunning"
  elseif s == "failed" and job.allow_failure then
    b.icon, b.icon_hl = "!", "GitlabStripPending"
  elseif s == "failed" then
    b.icon, b.icon_hl = "✗", "GitlabPipelineFailed"
  elseif s == "canceled" or s == "cancelled" then
    b.icon, b.icon_hl, b.name_hl = "⊘", "GitlabPipelineCanceled", "GitlabDetailMuted"
  elseif s == "skipped" then
    b.icon, b.icon_hl, b.name_hl = "»", "GitlabPipelineSkipped", "GitlabDetailMuted"
  elseif s == "manual" then
    b.dashed = true
    if job.playable ~= false then
      b.icon, b.icon_hl, b.right, b.right_hl = "▶", "GitlabStripPending", "manual", "GitlabStripPending"
    else
      b.icon, b.icon_hl, b.name_hl, b.right = "⏸", "GitlabDetailMuted", "GitlabDetailMuted", "blocked"
    end
  elseif M.is_active(s) then
    b.icon, b.icon_hl = "◷", "GitlabPipelinePending"
  end
  return b
end

--- The stage header: its name and a summary ("✓ 1:02", "◐ running").
---@param stage gg.PipelineStage
---@param now integer
---@return { [1]: string, [2]: string }[]
function M.stage_summary(stage, now)
  local jobs = stage.jobs or {}
  local s = norm(stage.status)
  local first, last
  for _, j in ipairs(jobs) do
    local a = date.parse_time(j.started_at)
    if a and (not first or a < first) then
      first = a
    end
    local b = date.parse_time(j.finished_at) or (M.is_active(j.status) and a and now or nil)
    if b and (not last or b > last) then
      last = b
    end
  end
  local span = first and last and date.clock(last - first) or ""
  local name_hl = "GitlabDetailValue"
  local out
  if s == "success" then
    out = { "✓ " .. span, "GitlabPipelineSuccess" }
  elseif s == "failed" then
    out = { "✗ " .. span, "GitlabPipelineFailed" }
  elseif s == "canceled" or s == "skipped" then
    out, name_hl = { "⊘ " .. span, "GitlabPipelineCanceled" }, "GitlabDetailMuted"
  elseif s == "running" then
    out, name_hl = { "◐ running", "GitlabPipelineRunning" }, "GitlabPipelineRunning"
  elseif s == "manual" then
    out, name_hl = { "manual", "GitlabStripPending" }, "GitlabStripPending"
  else
    out = { "◷ pending", "GitlabPipelinePending" }
  end
  return { { stage.name or "?", name_hl }, { " ", nil }, { vim.trim(out[1]), out[2] } }
end

--- The job to show first: the first running job, else the first failed
--- one that may not fail, else the first job.
---@param stages gg.PipelineStage[]
---@return integer|nil stage index
---@return integer|nil job index
function M.default_job(stages)
  for si, st in ipairs(stages or {}) do
    for ji, j in ipairs(st.jobs or {}) do
      if norm(j.status) == "running" then
        return si, ji
      end
    end
  end
  for si, st in ipairs(stages or {}) do
    for ji, j in ipairs(st.jobs or {}) do
      if norm(j.status) == "failed" and not j.allow_failure then
        return si, ji
      end
    end
  end
  for si, st in ipairs(stages or {}) do
    if st.jobs and st.jobs[1] then
      return si, 1
    end
  end
  return nil, nil
end

return M
