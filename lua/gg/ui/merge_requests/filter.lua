--- The merge request filter query. Pure.
---
--- Space-separated tokens; every token must match (AND); case-insensitive:
---   !12     the IID starts with 12
---   @user   an assignee, reviewer or the author contains `user`;
---           `@none` = unassigned
---   ~name   a label contains `name`
---   %name   the milestone title contains `name`; `%none` = no milestone
---   draft   draft merge requests (or "draft" in the title / branch)
---   other   a substring of the title or the source branch; a bare number
---           also matches IIDs starting with it
--- A lone prefix matches everything. Parsing is the shared `gg.ui.lib.filter`.
local filter = require("gg.ui.lib.filter")

local M = {}

local SPEC = {
  prefixes = { ["!"] = "iid", ["@"] = "user", ["~"] = "label", ["%"] = "milestone" },
  none = { user = true, milestone = true },
}

local contains = filter.contains

local function any_user(list, value)
  for _, u in ipairs(list or {}) do
    if contains(u.username, value) then
      return true
    end
  end
  return false
end

local MATCHERS = {
  iid = function(mr, t)
    return filter.iid_starts(mr.iid, t.value)
  end,
  user = function(mr, t)
    if t.none then
      return #(mr.assignees or {}) == 0
    end
    return any_user(mr.assignees, t.value) or any_user(mr.reviewers, t.value) or (mr.author ~= nil and contains(mr.author.username, t.value))
  end,
  label = function(mr, t)
    for _, l in ipairs(mr.labels or {}) do
      if contains(l.name, t.value) then
        return true
      end
    end
    return false
  end,
  milestone = function(mr, t)
    if t.none then
      return mr.milestone == nil
    end
    return mr.milestone ~= nil and contains(mr.milestone.title, t.value)
  end,
  text = function(mr, t)
    if t.value == "draft" and mr.draft then
      return true
    end
    return contains(mr.title, t.value) or contains(mr.source_branch, t.value) or filter.iid_starts(mr.iid, t.value)
  end,
}

--- Parse a query into tokens.
---@param query string|nil
---@return gg.ui.FilterToken[]
function M.parse(query)
  return filter.parse(query, SPEC)
end

--- True when `mr` matches every token.
---@param mr gg.MergeRequest
---@param tokens gg.ui.FilterToken[]
---@return boolean
function M.matches(mr, tokens)
  return filter.matches(mr, tokens, MATCHERS)
end

return M
