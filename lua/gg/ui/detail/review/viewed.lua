--- Which files of a review were marked viewed, kept across sessions.
---
--- GitLab has no API for it, so the marks live in one JSON file under
--- `stdpath("state")`, per merge request and head commit: new commits start
--- with nothing viewed.
local M = {}

M.MAX_REVIEWS = 200

--- The file the marks are kept in (tests point it elsewhere).
---@type string|nil
M.path = nil

local function file()
  return M.path or (vim.fn.stdpath("state") .. "/gg/review_viewed.json")
end

local function read()
  local f = io.open(file(), "r")
  if not f then
    return {}
  end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, raw)
  return ok and type(data) == "table" and data or {}
end

--- The key of one state of a merge request.
---@param host string
---@param project string|integer
---@param iid integer
---@param head_sha string|nil
---@return string
function M.key(host, project, iid, head_sha)
  return ("%s/%s!%d@%s"):format(host, tostring(project), iid, head_sha or "?")
end

--- The viewed paths stored under `key`.
---@param key string
---@return table<string, boolean>
function M.load(key)
  local entry = read()[key]
  local out = {}
  for _, p in ipairs(type(entry) == "table" and entry.paths or {}) do
    out[p] = true
  end
  return out
end

--- Store the viewed paths of `key` (the oldest reviews are dropped beyond
--- `MAX_REVIEWS`). Failing to write is not an error worth interrupting for.
---@param key string
---@param viewed table<string, boolean>
---@param now? integer epoch seconds
---@return boolean ok
function M.save(key, viewed, now)
  local data = read()
  local paths = {}
  for p, on in pairs(viewed) do
    if on then
      table.insert(paths, p)
    end
  end
  table.sort(paths)
  data[key] = #paths > 0 and { paths = paths, at = now or os.time() } or nil
  local keys = vim.tbl_keys(data)
  if #keys > M.MAX_REVIEWS then
    table.sort(keys, function(a, b)
      return (data[a].at or 0) > (data[b].at or 0)
    end)
    for i = M.MAX_REVIEWS + 1, #keys do
      data[keys[i]] = nil
    end
  end
  local path = file()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  if not f then
    return false
  end
  f:write(next(data) and vim.json.encode(data) or "{}")
  f:close()
  return true
end

return M
