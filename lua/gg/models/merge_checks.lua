--- Merge readiness of a merge request. Pure.
---
--- The atlas check list (labels, icons, "successful|failed|inprogress") is UI
--- and stays in atlas; this model keeps GitLab's values, lowercased.
local util = require("gg.models.util")

local M = {}

---@class gg.MergeCheck
---@field identifier string e.g. "ci_must_pass", "discussions_not_resolved"
---@field status string "success" | "checking" | "failed" | "inactive" | "warning"

---@class gg.MergeChecks
---@field draft boolean
---@field mergeable boolean|nil nil on older GitLab (fallback query)
---@field detailed_merge_status string|nil e.g. "mergeable", "ci_must_pass", "not_open"
---@field discussions_resolved boolean|nil all blocking threads resolved
---@field has_conflicts boolean
---@field head_pipeline_status string|nil e.g. "success", "failed", "running"
---@field approved boolean|nil
---@field approvals_required integer|nil
---@field approvals_left integer|nil
---@field resolvable_discussions integer|nil
---@field resolved_discussions integer|nil
---@field checks gg.MergeCheck[]|nil per-check results (newer GitLab)
---@field fallback boolean true when the older, smaller query was used

--- Map a GraphQL MergeRequest node selected by MrChecksFull or MrChecksBase.
---@param node table|nil
---@param fallback boolean
---@return gg.MergeChecks|nil
function M.from_graphql(node, fallback)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  local pipeline = util.value(node.headPipeline)
  local checks
  if util.value(node.mergeabilityChecks) ~= nil then
    checks = util.map(node.mergeabilityChecks, function(c)
      return { identifier = util.lower(c.identifier), status = util.lower(c.status) }
    end)
  end
  return {
    draft = util.value(node.draft) == true,
    mergeable = util.value(node.mergeable),
    detailed_merge_status = util.lower(node.detailedMergeStatus),
    discussions_resolved = util.value(node.mergeableDiscussionsState),
    has_conflicts = util.value(node.conflicts) == true,
    head_pipeline_status = pipeline and util.lower(pipeline.status) or nil,
    approved = util.value(node.approved),
    approvals_required = tonumber(util.value(node.approvalsRequired)),
    approvals_left = tonumber(util.value(node.approvalsLeft)),
    resolvable_discussions = tonumber(util.value(node.resolvableDiscussionsCount)),
    resolved_discussions = tonumber(util.value(node.resolvedDiscussionsCount)),
    checks = checks,
    fallback = fallback == true,
  }
end

return M
