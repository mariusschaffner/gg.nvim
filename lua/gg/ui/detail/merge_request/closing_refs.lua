--- Issues a merge request description closes ("Closes #12", "fixes
--- group/project#3 and #4"). Pure.
---
--- A keyword (close, fix, resolve, implement in any tense, any case), an
--- optional ":", an optional "issue"/"issues", then references separated by
--- ",", "and" or spaces. Fenced code is skipped; duplicates are dropped.
local M = {}

-- the open fence after a fence line `f` ("```" or "~~~"): opens one, or
-- closes the open one when it matches
local function toggle_fence(open, f)
  if open == nil then
    return f
  elseif open == f then
    return nil
  end
  return open
end

local KEYWORDS = {}
for _, stem in ipairs({ "close", "fix", "resolve", "implement" }) do
  for _, suffix in ipairs({ "", "s", "d", "ed", "es", "ing" }) do
    KEYWORDS[stem .. suffix] = true
  end
end
KEYWORDS["closing"], KEYWORDS["resolving"], KEYWORDS["implementing"], KEYWORDS["fixing"] = true, true, true, true

---@class gg.ui.ClosingRef
---@field project string|nil full path when the reference names another project
---@field iid integer
---@field line integer 1-based line of the description
---@field key string "path#iid" or "#iid"

-- the references in `s` starting at `pos`: "#1, #2 and group/x#3"
local function refs_after(s, pos)
  local out = {}
  local rest = s:sub(pos)
  rest = rest:gsub("^%s*:?%s*", "")
  rest = rest:gsub("^[Ii]ssues?%s+", "")
  while true do
    local path, iid, after = rest:match("^([%w%._/%-]*)#(%d+)()")
    if not iid then
      break
    end
    table.insert(out, { project = path ~= "" and path or nil, iid = tonumber(iid) })
    rest = rest:sub(after)
    local sep = rest:match("^%s*,%s*") or rest:match("^%s+and%s+") or rest:match("^%s*,?%s*and%s+") or rest:match("^%s+")
    if not sep or not rest:sub(#sep + 1):match("^[%w%._/%-]*#%d") then
      break
    end
    rest = rest:sub(#sep + 1)
  end
  return out
end

--- Parse the closing references of `description`.
---@param description string|nil
---@return gg.ui.ClosingRef[]
function M.parse(description)
  local out, seen, fence = {}, {}, nil
  local lines = vim.split(tostring(description or ""):gsub("\r", ""), "\n", { plain = true })
  for lnum, s in ipairs(lines) do
    local f = s:match("^%s*(```)") or s:match("^%s*(~~~)")
    if f then
      fence = toggle_fence(fence, f)
    elseif not fence then
      local pos = 1
      while true do
        local a, b, word = s:find("(%a+)", pos)
        if not a then
          break
        end
        if KEYWORDS[word:lower()] then
          for _, r in ipairs(refs_after(s, b + 1)) do
            r.key = (r.project or "") .. "#" .. r.iid
            r.line = lnum
            if not seen[r.key] then
              seen[r.key] = true
              table.insert(out, r)
            end
          end
        end
        pos = b + 1
      end
    end
  end
  return out
end

return M
