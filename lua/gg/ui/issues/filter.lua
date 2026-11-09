--- The issue filter query. Pure.
---
--- Space-separated tokens; every token must match (AND); case-insensitive:
---   ~name   a label contains `name`
---   %name   the milestone title contains `name`; `%none` = no milestone
---   @user   an assignee username contains `user`; `@none` = unassigned
---   #12     the IID starts with 12
---   other   a substring of the title; a bare number also matches IIDs
---           starting with it
--- A lone prefix (`~`, `%`, `@`, `#`) matches everything, so typing never
--- empties the table halfway through a token. Parsing and matching are the
--- shared `gg.ui.lib.filter`.
local filter = require("gg.ui.lib.filter")

local M = {}

local SPEC = {
  prefixes = { ["~"] = "label", ["%"] = "milestone", ["@"] = "assignee", ["#"] = "iid" },
  none = { milestone = true, assignee = true },
}

local contains = filter.contains

local MATCHERS = {
  label = function(issue, t)
    for _, l in ipairs(issue.labels or {}) do
      if contains(l.name, t.value) then
        return true
      end
    end
    return false
  end,
  milestone = function(issue, t)
    if t.none then
      return issue.milestone == nil
    end
    return issue.milestone ~= nil and contains(issue.milestone.title, t.value)
  end,
  assignee = function(issue, t)
    local assignees = issue.assignees or {}
    if t.none then
      return #assignees == 0
    end
    for _, u in ipairs(assignees) do
      if contains(u.username, t.value) then
        return true
      end
    end
    return false
  end,
  iid = function(issue, t)
    return filter.iid_starts(issue.iid, t.value)
  end,
  text = function(issue, t)
    return contains(issue.title, t.value) or filter.iid_starts(issue.iid, t.value)
  end,
}

--- Parse a query into tokens.
---@param query string|nil
---@return gg.ui.FilterToken[]
function M.parse(query)
  return filter.parse(query, SPEC)
end

--- True when `issue` matches every token.
---@param issue gg.Issue
---@param tokens gg.ui.FilterToken[]
---@return boolean
function M.matches(issue, tokens)
  return filter.matches(issue, tokens, MATCHERS)
end

return M
