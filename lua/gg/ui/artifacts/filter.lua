--- The artifacts filter. Pure.
---
--- Tokens (space-separated, all must match, case-insensitive):
---   text          a file, folder or job name, a ref, or "#<pipeline id>"
---   #<digits>     pipelines whose id starts with the digits
---   ref:<text>    the pipeline's ref
---   job:<text>    the job name
---   type:archive  archives; type:report: single-file reports
---   kept          artifacts with no expiry date
---   expiring      artifacts expiring within two days
---
--- A token is satisfied by a node or any of its ancestors, so `ref:main
--- job:build` finds the build artifacts of main pipelines. A node whose path
--- satisfies every token is a hit. The filter shows every hit and all of its
--- ancestors, and hides the rest. It opens the ancestors of the topmost
--- hits, which are only ever inside archives that are already listed (the
--- tree has no entries for the others), so filtering never downloads.
local expires = require("gg.ui.artifacts.expires")
local lib = require("gg.ui.lib.filter")

local M = {}

local SPEC = {
  prefixes = { ["#"] = "id" },
  keys = { ref = "ref", job = "job", type = "type" },
}

local WORDS = { kept = "kept", expiring = "expiring" }

--- Parse a query into tokens.
---@param query string|nil
---@return gg.ui.FilterToken[]
function M.parse(query)
  local tokens = lib.parse(query, SPEC)
  for _, t in ipairs(tokens) do
    if t.kind == "text" and WORDS[t.value] then
      t.kind = WORDS[t.value]
    end
  end
  return tokens
end

local function starts(s, prefix)
  return s:sub(1, #prefix) == prefix
end

-- does `node` itself satisfy token `t`?
local MATCHERS = {
  text = function(n, t)
    if n.kind == "pipeline" then
      return lib.contains(n.pipeline.ref, t.value) or lib.contains(n.name, t.value)
    end
    if n.kind == "artifact" then
      return lib.contains(n.job.name, t.value) or lib.contains(n.name, t.value)
    end
    return lib.contains(n.name, t.value)
  end,
  id = function(n, t)
    return n.kind == "pipeline" and lib.iid_starts(n.pipeline.id, t.value)
  end,
  ref = function(n, t)
    return n.kind == "pipeline" and lib.contains(n.pipeline.ref, t.value)
  end,
  job = function(n, t)
    return n.kind == "artifact" and lib.contains(n.job.name, t.value)
  end,
  type = function(n, t)
    if n.kind ~= "artifact" then
      return false
    end
    return starts(n.archive and "archive" or "report", t.value)
  end,
  kept = function(n)
    return n.kind == "artifact" and expires.kept(n.artifact)
  end,
  expiring = function(n, _, now)
    return n.kind == "artifact" and expires.expiring(n.artifact, now)
  end,
}

---@class gg.ui.ArtifactFilterResult
---@field visible table<string, boolean> hits and their ancestors
---@field auto_open table<string, boolean> ancestors of the topmost hits
---@field hits integer

--- Apply tokens to a tree. nil when there are no tokens (show everything).
---@param tree gg.ui.ArtifactTree
---@param tokens gg.ui.FilterToken[]
---@param now integer epoch seconds
---@return gg.ui.ArtifactFilterResult|nil
function M.apply(tree, tokens, now)
  if #tokens == 0 then
    return nil
  end
  local res = { visible = {}, auto_open = {}, hits = 0 }
  local path = {}
  local function walk(n, done, parent_hit)
    local mine = {}
    local all = true
    for i, t in ipairs(tokens) do
      local ok = done[i] or MATCHERS[t.kind](n, t, now)
      mine[i] = ok
      all = all and ok
    end
    table.insert(path, n)
    if all then
      res.hits = res.hits + 1
      for _, a in ipairs(path) do
        res.visible[a.id] = true
      end
      if not parent_hit then
        for k = 1, #path - 1 do
          res.auto_open[path[k].id] = true
        end
      end
    end
    for _, c in ipairs(n.children) do
      walk(c, mine, all)
    end
    table.remove(path)
  end
  for _, r in ipairs(tree.roots) do
    walk(r, {}, false)
  end
  return res
end

return M
