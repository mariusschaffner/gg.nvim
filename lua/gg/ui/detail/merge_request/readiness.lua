--- Merge readiness: the gates in front of a merge request and the one
--- that blocks it. Pure.
---
--- Gates, in order (a gate that does not apply is left out):
---   Pipeline   a head pipeline exists, or GitLab waits for one
---   Conflicts  always
---   Review     there are reviewers or approvers
---   Threads    there are resolvable threads, or GitLab waits for them
---   Draft      the merge request is a draft
--- then the merge node. GitLab's `detailed_merge_status` names the
--- blocking gate when it can; otherwise the first gate that has not passed.
local M = {}

---@alias gg.ui.GateState "passed"|"pending"|"failed"

---@class gg.ui.Gate
---@field key "pipeline"|"conflicts"|"review"|"threads"|"draft"
---@field state gg.ui.GateState
---@field label string
---@field short string one word for the compact strip
---@field reason? string what to do about it (the hint under a blocking gate)

---@class gg.ui.Readiness
---@field gates gg.ui.Gate[]
---@field blocking string|nil key of the blocking gate
---@field merge { state: "ready"|"blocked"|"merged"|"closed", label: string, reason?: string }

local DMS_GATE = {
  ci_must_pass = "pipeline",
  ci_still_running = "pipeline",
  conflict = "conflicts",
  not_approved = "review",
  approvals_syncing = "review",
  requested_changes = "review",
  discussions_not_resolved = "threads",
  draft_status = "draft",
}

local DMS_REASON = {
  need_rebase = "needs rebase",
  blocked_status = "blocked by a dependency",
  not_open = "not open",
  jira_association_missing = "Jira issue missing",
  external_status_checks = "external checks",
  locked_paths = "locked files",
  locked_lfs_files = "locked files",
  merge_request_blocked = "blocked",
  security_policy_violations = "policy violation",
  commits_status = "commit status",
  unchecked = "checking",
  checking = "checking",
  merge_time = "merge time not reached",
  title_regex = "title format",
}

local CHECKING = { checking = true, unchecked = true, preparing = true, approvals_syncing = false }

local function names(list)
  local out = {}
  for _, r in ipairs(list) do
    table.insert(out, r.user and r.user.username or "?")
  end
  return table.concat(out, ", ")
end

---@class gg.ui.ReadinessInput
---@field mr gg.MergeRequest
---@field checks gg.MergeChecks
---@field reviewers? gg.Reviewer[]

--- Compute the gates.
---@param input gg.ui.ReadinessInput
---@return gg.ui.Readiness
function M.compute(input)
  local mr, c = input.mr, input.checks or {}
  local dms = c.detailed_merge_status or mr.detailed_merge_status
  local target = mr.target_branch or "target"
  local gates = {}

  local pstatus = c.head_pipeline_status and c.head_pipeline_status:lower()
  if pstatus or dms == "ci_must_pass" or dms == "ci_still_running" then
    local g = { key = "pipeline", short = "pipeline" }
    if pstatus == "success" or pstatus == "skipped" then
      g.state, g.label = "passed", "Pipeline passed"
    elseif pstatus == "failed" or pstatus == "canceled" or pstatus == "cancelled" then
      g.state, g.label, g.reason = "failed", "Pipeline failed", "fix the pipeline"
    elseif pstatus == nil then
      g.state, g.label, g.reason = "pending", "Pipeline required", "run a pipeline"
    else
      g.state, g.label, g.reason = "pending", "Pipeline running", "wait for the pipeline"
    end
    table.insert(gates, g)
  end

  local conflicts = { key = "conflicts", short = "conflicts" }
  if c.has_conflicts or mr.has_conflicts or dms == "conflict" then
    conflicts.state, conflicts.label, conflicts.reason = "failed", "Conflicts with " .. target, "resolve conflicts"
  elseif CHECKING[dms] then
    conflicts.state, conflicts.label = "pending", "Checking…"
  else
    conflicts.state, conflicts.label, conflicts.short = "passed", "No conflicts", "no conflicts"
  end
  table.insert(gates, conflicts)

  local reviewers = vim.tbl_filter(function(r)
    return r.role ~= "participant"
  end, input.reviewers or {})
  local approvers = vim.tbl_filter(function(r)
    return r.approved
  end, input.reviewers or {})
  if #reviewers > 0 or #approvers > 0 then
    local g = { key = "review", short = "review" }
    local changes = vim.tbl_filter(function(r)
      return r.review_state == "requested_changes"
    end, reviewers)
    local approved = c.approved == true or (c.approved == nil and #approvers > 0)
    if #changes > 0 then
      g.state, g.label, g.reason = "failed", "Changes requested · " .. names(changes), "address the changes"
    elseif approved and dms ~= "not_approved" and dms ~= "approvals_syncing" then
      g.state, g.label = "passed", "Approved · " .. names(approvers)
    else
      g.state, g.label, g.reason = "pending", "Review · " .. names(reviewers), "waiting for approval"
    end
    if g.label:match("· $") then
      g.label = g.label:gsub(" · $", "")
    end
    table.insert(gates, g)
  end

  local resolvable = c.resolvable_discussions or 0
  local resolved = c.resolved_discussions or 0
  if resolvable > 0 or c.discussions_resolved == false or dms == "discussions_not_resolved" then
    local g = { key = "threads", short = "threads" }
    if c.discussions_resolved == false or dms == "discussions_not_resolved" then
      local open = math.max(0, resolvable - resolved)
      g.state = "failed"
      g.label = open > 0 and ("%d unresolved thread%s"):format(open, open == 1 and "" or "s") or "Unresolved threads"
      g.reason = "resolve threads"
    else
      g.state, g.label = "passed", "Threads resolved"
    end
    table.insert(gates, g)
  end

  if mr.draft or c.draft then
    table.insert(gates, { key = "draft", short = "draft", state = "failed", label = "Marked as draft", reason = "mark as ready" })
  end

  local result = { gates = gates }
  if mr.state == "merged" then
    -- history now: every gate green, with neutral labels
    -- (the pipeline gate has no label: its "[gp] pipeline" hint names it)
    local neutral = { pipeline = "", conflicts = "No conflicts", threads = "Threads", draft = "Ready" }
    for _, g in ipairs(gates) do
      g.state, g.reason = "passed", nil
      if neutral[g.key] then
        g.label = neutral[g.key]
      elseif g.key == "review" then
        g.label = g.label:gsub("^Changes requested", "Reviewed"):gsub("^Review ·", "Reviewed ·")
      end
    end
    result.merge = { state = "merged", label = "Merged into " .. target }
    return result
  end
  if mr.state == "closed" then
    result.merge = { state = "closed", label = "Closed" }
    return result
  end

  local blocking = DMS_GATE[dms]
  local has = {}
  for _, g in ipairs(gates) do
    has[g.key] = g
  end
  if not (blocking and has[blocking] and has[blocking].state ~= "passed") then
    blocking = nil
    for _, g in ipairs(gates) do
      if g.state ~= "passed" then
        blocking = g.key
        break
      end
    end
  end
  result.blocking = blocking
  if not blocking and (dms == nil or dms == "mergeable") then
    result.merge = { state = "ready", label = "Ready to merge" }
  else
    local reason
    if not blocking and dms then
      reason = DMS_REASON[dms] or dms:gsub("_", " ")
    end
    result.merge = { state = "blocked", label = "Merge into " .. target, reason = reason }
  end
  return result
end

local GLYPH = {
  passed = { "✓", "GitlabStripDone" },
  pending = { "◷", "GitlabStripPending" },
  failed = { "✗", "GitlabStripFailed" },
}

--- Strip nodes (`gg.ui.lib.strip`) for the readiness.
---@param r gg.ui.Readiness
---@param opts? { pipeline_key?: string } the key that opens the pipeline (a hint under its gate)
---@return gg.ui.StripNode[]
function M.nodes(r, opts)
  opts = opts or {}
  local nodes = {}
  for _, g in ipairs(r.gates) do
    local glyph = GLYPH[g.state]
    local blocking = r.blocking == g.key
    local hint = {}
    if g.key == "pipeline" and opts.pipeline_key then
      vim.list_extend(hint, { { "[" .. opts.pipeline_key .. "]", "GitlabHintKey" }, { " pipeline", "GitlabStripMuted" } })
    end
    if blocking and g.reason then
      if #hint > 0 then
        table.insert(hint, { " · ", "GitlabStripMuted" })
      end
      table.insert(hint, { g.reason, glyph[2] })
    end
    table.insert(nodes, {
      glyph = glyph[1],
      hl = glyph[2],
      done = g.state == "passed",
      label = g.label,
      short = g.short,
      label_hl = blocking and glyph[2] or "GitlabStripMuted",
      hint = hint,
    })
  end
  local m = r.merge
  local node
  if m.state == "merged" then
    node = { glyph = "●", hl = "GitlabStripMerged", label = m.label, short = "merged", label_hl = "GitlabStripMerged" }
  elseif m.state == "closed" then
    node = { glyph = "✗", hl = "GitlabStripMuted", label = m.label, short = "closed" }
  elseif m.state == "ready" then
    node = { glyph = "⇣", hl = "GitlabStripDone", label = m.label, short = "ready", label_hl = "GitlabStripDone" }
  else
    node = {
      glyph = "⇣",
      hl = "GitlabStripMuted",
      label = m.label,
      short = "merge",
      hint = { { m.reason and (m.reason .. " · blocked") or "blocked", "GitlabStripMuted" } },
    }
  end
  node.done = false
  table.insert(nodes, node)
  return nodes
end

return M
