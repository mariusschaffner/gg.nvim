--- CI pipeline model, including the stage -> group -> job graph. Pure.
---
--- Statuses are GitLab's, lowercased.
local gid = require("gg.models.gid")
local job = require("gg.models.job")
local user = require("gg.models.user")
local util = require("gg.models.util")

local M = {}

---@class gg.PipelineGroup
---@field name string
---@field size integer|nil
---@field jobs gg.Job[]

---@class gg.PipelineStage
---@field name string
---@field status string|nil
---@field groups gg.PipelineGroup[]|nil only from `graph`
---@field jobs gg.Job[]|nil only from `graph` (all jobs of the stage, in order)

---@class gg.Pipeline
---@field id integer
---@field iid integer|nil
---@field project string|nil full path
---@field status string "created", "pending", "running", "success", "failed", "canceled", "skipped", "manual", "scheduled", ...
---@field ref string|nil
---@field sha string|nil
---@field short_sha string|nil
---@field source string|nil "push", "merge_request_event", "schedule", ...
---@field user gg.User|nil
---@field merge_request { iid: integer, title: string }|nil only from `graph`
---@field created_at string|nil
---@field started_at string|nil
---@field finished_at string|nil
---@field duration integer|nil seconds
---@field queued_duration number|nil seconds
---@field web_url string|nil
---@field commit_title string|nil
---@field total_jobs integer|nil
---@field retryable boolean|nil
---@field cancelable boolean|nil
---@field stages gg.PipelineStage[]|nil
---@field truncated gg.Truncated|nil

local function stages_from_graphql(conn, ctx, truncated)
  if util.value(conn) == nil then
    return nil
  end
  if util.has_more(conn) then
    truncated.stages = true
  end
  return util.map(util.nodes(conn), function(s)
    local stage = { name = util.value(s.name), status = util.lower(s.status) }
    if util.value(s.groups) ~= nil then
      if util.has_more(s.groups) then
        truncated.jobs = true
      end
      stage.groups, stage.jobs = {}, {}
      for _, g in ipairs(util.nodes(s.groups)) do
        if util.has_more(g.jobs) then
          truncated.jobs = true
        end
        local jobs = util.map(util.nodes(g.jobs), function(j)
          return job.from_graphql(j, ctx)
        end)
        table.insert(stage.groups, { name = util.value(g.name), size = tonumber(util.value(g.size)), jobs = jobs })
        vim.list_extend(stage.jobs, jobs)
      end
    end
    return stage
  end)
end

--- Map a GraphQL Pipeline node (PipelineFields, plus `graph` and
--- `mergeRequest` for PipelineGraph). The graph's stages replace the summary
--- stages when present.
---@param node table|nil
---@param ctx? { origin?: string, project?: string }
---@return gg.Pipeline|nil
function M.from_graphql(node, ctx)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  ctx = ctx or {}
  local truncated = {}
  local stages = stages_from_graphql(util.value(node.graph) or node.stages, ctx, truncated)
  local mr = util.value(node.mergeRequest)
  local commit = util.value(node.commit)
  return {
    id = gid.tail(util.value(node.id)),
    iid = tonumber(util.value(node.iid)),
    project = ctx.project,
    status = util.lower(node.status),
    ref = util.value(node.ref),
    sha = util.value(node.sha),
    short_sha = util.value(node.shortSha),
    source = util.value(node.source),
    user = user.from_graphql(node.user, ctx),
    merge_request = mr and { iid = tonumber(util.value(mr.iid)), title = util.value(mr.title) } or nil,
    created_at = util.value(node.createdAt),
    started_at = util.value(node.startedAt),
    finished_at = util.value(node.finishedAt),
    duration = tonumber(util.value(node.duration)),
    queued_duration = tonumber(util.value(node.queuedDuration)),
    web_url = util.web_url(node.path, ctx.origin),
    commit_title = commit and util.value(commit.title) or nil,
    total_jobs = tonumber(util.value(node.totalJobs)),
    retryable = util.value(node.retryable),
    cancelable = util.value(node.cancelable),
    stages = stages,
    truncated = next(truncated) and truncated or nil,
  }
end

--- Map a REST pipeline (`/pipelines/:id`, retry, cancel).
---@param raw table|nil
---@param ctx? { origin?: string, project?: string }
---@return gg.Pipeline|nil
function M.from_rest(raw, ctx)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  ctx = ctx or {}
  local sha = util.value(raw.sha)
  return {
    id = tonumber(util.value(raw.id)),
    iid = tonumber(util.value(raw.iid)),
    project = ctx.project,
    status = util.value(raw.status),
    ref = util.value(raw.ref),
    sha = sha,
    short_sha = type(sha) == "string" and sha:sub(1, 8) or nil,
    source = util.value(raw.source),
    user = user.from_rest(raw.user, ctx),
    created_at = util.value(raw.created_at),
    started_at = util.value(raw.started_at),
    finished_at = util.value(raw.finished_at),
    duration = tonumber(util.value(raw.duration)),
    queued_duration = tonumber(util.value(raw.queued_duration)),
    web_url = util.value(raw.web_url),
  }
end

return M
