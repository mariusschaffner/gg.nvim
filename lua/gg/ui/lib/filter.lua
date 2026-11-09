--- A filter query: space-separated tokens that must all match (AND),
--- case-insensitive. Shared by the pickers; each view brings its prefixes and
--- matchers. Pure.
---
--- A token starting with a known prefix (e.g. `~`) has that prefix's kind; a
--- lone prefix matches everything, so typing never empties the table halfway
--- through a token. Everything else is a "text" token.
local M = {}

---@class gg.ui.FilterToken
---@field kind string a prefix kind, or "text"
---@field value string lowercase, without the prefix
---@field none? boolean `<prefix>none` for kinds that accept it

---@class gg.ui.FilterSpec
---@field prefixes table<string, string> one-character prefix -> kind
---@field none? table<string, boolean> kinds where "none" means "has none"

--- Parse a query into tokens.
---@param query string|nil
---@param spec gg.ui.FilterSpec
---@return gg.ui.FilterToken[]
function M.parse(query, spec)
  local tokens = {}
  local none = spec.none or {}
  for word in (query or ""):gmatch("%S+") do
    word = word:lower()
    local kind = spec.prefixes[word:sub(1, 1)]
    if kind then
      local value = word:sub(2)
      if value ~= "" then
        table.insert(tokens, { kind = kind, value = value, none = none[kind] and value == "none" or nil })
      end
    else
      table.insert(tokens, { kind = "text", value = word })
    end
  end
  return tokens
end

--- True when `haystack` contains the lowercase `needle` (case-insensitive).
---@param haystack string|nil
---@param needle string
---@return boolean
function M.contains(haystack, needle)
  return haystack ~= nil and haystack:lower():find(needle, 1, true) ~= nil
end

--- True when `digits` is all digits and `iid` starts with them.
---@param iid integer|nil
---@param digits string
---@return boolean
function M.iid_starts(iid, digits)
  return digits:match("^%d+$") ~= nil and tostring(iid or ""):sub(1, #digits) == digits
end

--- True when `item` matches every token. `matchers[kind](item, token)`
--- decides one token; kinds without a matcher never match.
---@param item any
---@param tokens gg.ui.FilterToken[]
---@param matchers table<string, fun(item: any, t: gg.ui.FilterToken): boolean>
---@return boolean
function M.matches(item, tokens, matchers)
  for _, t in ipairs(tokens) do
    local fn = matchers[t.kind]
    if not (fn and fn(item, t)) then
      return false
    end
  end
  return true
end

return M
