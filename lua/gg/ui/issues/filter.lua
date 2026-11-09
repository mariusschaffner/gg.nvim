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
--- empties the table halfway through a token.
local M = {}

---@class gg.ui.FilterToken
---@field kind "label"|"milestone"|"assignee"|"iid"|"text"
---@field value string lowercase
---@field none? boolean `%none` / `@none`

local KINDS = { ["~"] = "label", ["%"] = "milestone", ["@"] = "assignee", ["#"] = "iid" }

--- Parse a query into tokens.
---@param query string|nil
---@return gg.ui.FilterToken[]
function M.parse(query)
  local tokens = {}
  for word in (query or ""):gmatch("%S+") do
    word = word:lower()
    local kind = KINDS[word:sub(1, 1)]
    if kind then
      local value = word:sub(2)
      if value ~= "" then
        table.insert(tokens, {
          kind = kind,
          value = value,
          none = (kind == "milestone" or kind == "assignee") and value == "none" or nil,
        })
      end
    else
      table.insert(tokens, { kind = "text", value = word })
    end
  end
  return tokens
end

local function contains(haystack, needle)
  return haystack ~= nil and haystack:lower():find(needle, 1, true) ~= nil
end

local function iid_starts(issue, digits)
  return digits:match("^%d+$") ~= nil and tostring(issue.iid or ""):sub(1, #digits) == digits
end

local function token_matches(issue, t)
  if t.kind == "label" then
    for _, l in ipairs(issue.labels or {}) do
      if contains(l.name, t.value) then
        return true
      end
    end
    return false
  elseif t.kind == "milestone" then
    if t.none then
      return issue.milestone == nil
    end
    return issue.milestone ~= nil and contains(issue.milestone.title, t.value)
  elseif t.kind == "assignee" then
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
  elseif t.kind == "iid" then
    return iid_starts(issue, t.value)
  end
  return contains(issue.title, t.value) or iid_starts(issue, t.value)
end

--- True when `issue` matches every token.
---@param issue gg.Issue
---@param tokens gg.ui.FilterToken[]
---@return boolean
function M.matches(issue, tokens)
  for _, t in ipairs(tokens) do
    if not token_matches(issue, t) then
      return false
    end
  end
  return true
end

return M
