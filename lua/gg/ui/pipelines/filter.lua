--- The pipeline filter query. Pure.
---
--- Space-separated tokens; every token must match (AND); case-insensitive:
---   status:<s>   the GitLab status or the shown word starts with s
---                (`status:failed`, `status:waiting`, `status:passed`)
---   source:<s>   the source label or GitLab's source contains s
---                (`source:schedule`, `source:mr`)
---   ref:<text>   the ref contains text
---   @user        triggered by a user whose username contains user
---   #4821        the pipeline id starts with 4821
---   !87          the linked merge request's IID starts with 87
---   other        a substring of the ref, the commit title or the SHA; a
---                bare number also matches ids starting with it
--- A lone prefix (or `key:`) matches everything. Parsing is the shared
--- `gg.ui.lib.filter`.
local filter = require("gg.ui.lib.filter")
local pipeline_status = require("gg.ui.lib.pipeline_status")

local M = {}

local SPEC = {
  prefixes = { ["#"] = "id", ["!"] = "mr", ["@"] = "user" },
  keys = { status = "status", source = "source", ref = "ref" },
}

local contains = filter.contains

local function starts(s, value)
  return s ~= nil and s:lower():sub(1, #value) == value
end

---@class gg.ui.PipelineFilterExtra values derived outside the filter
---@field mr fun(): integer|nil the linked merge request's IID
---@field source string the source label
---@field ref string the shown ref

local MATCHERS = {
  status = function(p, t)
    return starts(p.status, t.value) or starts(pipeline_status.word(p.status), t.value)
  end,
  source = function(p, t, x)
    return contains(x.source, t.value) or contains(p.source, t.value)
  end,
  ref = function(p, t, x)
    return contains(x.ref, t.value) or contains(p.ref, t.value)
  end,
  user = function(p, t)
    return p.user ~= nil and contains(p.user.username, t.value)
  end,
  id = function(p, t)
    return filter.iid_starts(p.id, t.value)
  end,
  mr = function(_, t, x)
    local iid = x.mr()
    return iid ~= nil and filter.iid_starts(iid, t.value)
  end,
  text = function(p, t, x)
    return contains(x.ref, t.value)
      or contains(p.ref, t.value)
      or contains(p.commit_title, t.value)
      or contains(p.sha, t.value)
      or filter.iid_starts(p.id, t.value)
  end,
}

--- Parse a query into tokens.
---@param query string|nil
---@return gg.ui.FilterToken[]
function M.parse(query)
  return filter.parse(query, SPEC)
end

--- True when pipeline `p` matches every token.
---@param p gg.Pipeline
---@param tokens gg.ui.FilterToken[]
---@param extra gg.ui.PipelineFilterExtra
---@return boolean
function M.matches(p, tokens, extra)
  local matchers = {}
  for kind, fn in pairs(MATCHERS) do
    matchers[kind] = function(item, t)
      return fn(item, t, extra)
    end
  end
  return filter.matches(p, tokens, matchers)
end

return M
