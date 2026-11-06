--- CI job model. Pure.
---
--- Statuses are GitLab's, lowercased ("success", "failed", "manual", ...).
--- atlas's STOPPED/INPROGRESS grouping is UI and stays in atlas.
local gid = require("gg.models.gid")
local user = require("gg.models.user")
local util = require("gg.models.util")

local M = {}

---@class gg.JobArtifact
---@field file_type string "archive", "trace", "junit", ...
---@field filename string|nil
---@field size integer|nil bytes
---@field file_format string|nil

---@class gg.Job
---@field id integer
---@field name string
---@field stage string|nil
---@field status string "created", "pending", "running", "success", "failed", "canceled", "skipped", "manual", ...
---@field allow_failure boolean
---@field manual boolean
---@field playable boolean|nil GraphQL only
---@field retryable boolean|nil GraphQL only
---@field cancelable boolean|nil GraphQL only
---@field duration number|nil seconds
---@field queued_duration number|nil seconds
---@field created_at string|nil
---@field started_at string|nil
---@field finished_at string|nil
---@field web_url string|nil
---@field ref string|nil
---@field short_sha string|nil
---@field pipeline_id integer|nil REST only
---@field user gg.User|nil REST only
---@field artifacts gg.JobArtifact[]|nil REST only

--- Map a GraphQL CiJob node (JobFields).
---@param node table|nil
---@param ctx? { origin?: string }
---@return gg.Job|nil
function M.from_graphql(node, ctx)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  local stage = util.value(node.stage)
  return {
    id = gid.tail(util.value(node.id)),
    name = util.value(node.name),
    stage = stage and util.value(stage.name) or nil,
    status = util.lower(node.status),
    allow_failure = util.value(node.allowFailure) == true,
    manual = util.value(node.manualJob) == true,
    playable = util.value(node.playable),
    retryable = util.value(node.retryable),
    cancelable = util.value(node.cancelable),
    duration = tonumber(util.value(node.duration)),
    queued_duration = tonumber(util.value(node.queuedDuration)),
    created_at = util.value(node.createdAt),
    started_at = util.value(node.startedAt),
    finished_at = util.value(node.finishedAt),
    web_url = util.web_url(node.webPath, ctx and ctx.origin),
    ref = util.value(node.refName),
    short_sha = util.value(node.shortSha),
  }
end

--- Map a REST job (`/jobs/:id`, `/pipelines/:id/jobs`, job actions).
---@param raw table|nil
---@param ctx? { origin?: string }
---@return gg.Job|nil
function M.from_rest(raw, ctx)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local pipeline = util.value(raw.pipeline) or {}
  local commit = util.value(raw.commit) or {}
  local status = util.value(raw.status)
  return {
    id = tonumber(util.value(raw.id)),
    name = util.value(raw.name),
    stage = util.value(raw.stage),
    status = status,
    allow_failure = util.value(raw.allow_failure) == true,
    manual = util.value(raw.when) == "manual" or status == "manual",
    duration = tonumber(util.value(raw.duration)),
    queued_duration = tonumber(util.value(raw.queued_duration)),
    created_at = util.value(raw.created_at),
    started_at = util.value(raw.started_at),
    finished_at = util.value(raw.finished_at),
    web_url = util.value(raw.web_url),
    ref = util.value(raw.ref),
    short_sha = util.value(commit.short_id),
    pipeline_id = tonumber(util.value(pipeline.id)),
    user = user.from_rest(raw.user, ctx),
    artifacts = util.map(raw.artifacts, function(a)
      return {
        file_type = util.value(a.file_type),
        filename = util.value(a.filename),
        size = tonumber(util.value(a.size)),
        file_format = util.value(a.file_format),
      }
    end),
  }
end

return M
