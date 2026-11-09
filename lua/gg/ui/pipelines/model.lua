--- Pipelines table model: tab membership, source labels, the shown ref and
--- merge request, filter and order. Pure.
---
--- One row per pipeline, newest (highest id) first, no grouping.
local filter = require("gg.ui.pipelines.filter")

local M = {}

---@alias gg.ui.PipelineTab "all"|"running"|"failed"|"passed"

M.TABS = { "all", "running", "failed", "passed" }

-- the Running tab
local RUNNING = {
  running = true,
  pending = true,
  created = true,
  preparing = true,
  waiting_for_resource = true,
}

-- statuses that can still change (the live refresh polls these)
local ACTIVE = {
  running = true,
  pending = true,
  created = true,
  preparing = true,
  waiting_for_resource = true,
  waiting_for_callback = true,
  canceling = true,
}

local SOURCES = {
  push = "push",
  merge_request_event = "MR",
  external_pull_request_event = "MR",
  schedule = "schedule",
  web = "manual",
  api = "api",
  trigger = "trigger",
  pipeline = "trigger",
  parent_pipeline = "child",
}

---@class gg.ui.PipelineCtx
---@field default_branch? string nil until the project has loaded
---@field mr_by_branch? table<string, integer> open merge requests by source branch; nil while loading
---@field mr_failed? boolean the open merge requests could not be loaded

---@class gg.ui.PipelineModel
---@field tab gg.ui.PipelineTab
---@field counts { all: integer, running: integer, failed: integer, passed: integer } per tab, unfiltered
---@field matching integer
---@field total integer rows in the active tab
---@field filtered boolean
---@field rows gg.Pipeline[] matching rows, newest first

--- The tab a pipeline belongs to besides All (nil: All only).
---@param p gg.Pipeline
---@return "running"|"failed"|"passed"|nil
function M.tab_of(p)
  local s = p.status
  if RUNNING[s] then
    return "running"
  elseif s == "failed" then
    return "failed"
  elseif s == "success" then
    return "passed"
  end
  return nil
end

--- True while the pipeline's status can still change.
---@param p gg.Pipeline
---@return boolean
function M.is_active(p)
  return ACTIVE[p.status] == true
end

--- The short label of a pipeline source ("push", "MR", "schedule",
--- "manual", "api", "trigger", "child"); others as they are.
---@param source string|nil
---@return string
function M.source_label(source)
  if source == nil then
    return ""
  end
  return SOURCES[source] or source
end

--- The merge request IID in a merge request ref
--- ("refs/merge-requests/87/head" -> 87).
---@param ref string|nil
---@return integer|nil
function M.mr_ref_iid(ref)
  local iid = type(ref) == "string" and ref:match("^refs/merge%-requests/(%d+)/")
  return iid and tonumber(iid) or nil
end

--- The ref to show: the branch or tag name; for a merge request pipeline
--- its source branch when GitLab gave the ref path.
---@param p gg.Pipeline
---@return string
function M.display_ref(p)
  local ref = p.ref or ""
  if M.mr_ref_iid(ref) and type(p.ref_path) == "string" then
    local branch = p.ref_path:match("^refs/heads/(.+)$")
    if branch then
      return branch
    end
  end
  return ref
end

--- The merge request a pipeline belongs to: the pipeline's own (MR
--- pipelines), else the open merge request of its branch.
---@param p gg.Pipeline
---@param ctx? gg.ui.PipelineCtx
---@return integer|nil iid
---@return boolean loading the open merge requests are still loading
function M.mr_of(p, ctx)
  if p.merge_request and p.merge_request.iid then
    return p.merge_request.iid, false
  end
  local from_ref = M.mr_ref_iid(p.ref)
  if from_ref then
    return from_ref, false
  end
  if p.tag or not p.ref or p.ref == "" then
    return nil, false
  end
  ctx = ctx or {}
  if ctx.mr_by_branch then
    return ctx.mr_by_branch[p.ref], false
  end
  return nil, not ctx.mr_failed
end

--- Open merge requests by source branch, only those whose source branch
--- is in this project (`project_id`; any when nil). With several per
--- branch, the most recently updated one wins.
---@param mrs gg.MergeRequest[]
---@param project_id? integer
---@return table<string, integer>
function M.mr_map(mrs, project_id)
  local out, at = {}, {}
  for _, mr in ipairs(mrs) do
    local here = project_id == nil or mr.source_project_id == nil or mr.source_project_id == project_id
    if here and mr.source_branch and (at[mr.source_branch] == nil or (mr.updated_at or "") > at[mr.source_branch]) then
      out[mr.source_branch] = mr.iid
      at[mr.source_branch] = mr.updated_at or ""
    end
  end
  return out
end

--- Build the model for one tab and filter.
---@param pipelines gg.Pipeline[] every loaded pipeline
---@param opts { tab?: gg.ui.PipelineTab, query?: string, ctx?: gg.ui.PipelineCtx }
---@return gg.ui.PipelineModel
function M.build(pipelines, opts)
  local tab = opts.tab or "all"
  local tokens = filter.parse(opts.query)
  local counts = { all = #pipelines, running = 0, failed = 0, passed = 0 }
  local rows, total = {}, 0
  for _, p in ipairs(pipelines) do
    local t = M.tab_of(p)
    if t then
      counts[t] = counts[t] + 1
    end
    if tab == "all" or t == tab then
      total = total + 1
      if filter.matches(p, tokens, {
        mr = function()
          return (M.mr_of(p, opts.ctx))
        end,
        source = M.source_label(p.source),
        ref = M.display_ref(p),
      }) then
        table.insert(rows, p)
      end
    end
  end
  table.sort(rows, function(a, b)
    return (a.id or 0) > (b.id or 0)
  end)
  return { tab = tab, counts = counts, matching = #rows, total = total, filtered = #tokens > 0, rows = rows }
end

return M
