-- Shared helpers for the test suite. Test-only code: blocking waits are allowed here.
local H = {}

H.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"):gsub("\\", "/")

--- Absolute path inside the repository.
---@param rel string
---@return string
function H.path(rel)
  return H.root .. "/" .. rel
end

--- Read a whole file (relative to the repo root or absolute).
---@param path string
---@return string
function H.read(path)
  if not path:match("^%a:[/\\]") and not path:match("^/") then
    path = H.path(path)
  end
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

--- Recursively list files under `dir` (relative to the repo root) whose name matches `pattern`.
---@param dir string
---@param pattern string Lua pattern matched against the file name
---@return string[] paths relative to the repo root, sorted
function H.files(dir, pattern)
  local out = {}
  local abs = H.path(dir)
  if vim.fn.isdirectory(abs) == 0 then
    return out
  end
  for name, kind in vim.fs.dir(abs, { depth = 20 }) do
    if kind == "file" and vim.fs.basename(name):match(pattern) then
      table.insert(out, dir .. "/" .. (name:gsub("\\", "/")))
    end
  end
  table.sort(out)
  return out
end

--- Lua module name for a file under lua/ (e.g. "lua/gg/core/task.lua" -> "gg.core.task").
---@param rel string
---@return string
function H.module_name(rel)
  local mod = rel:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/", ".")
  mod = mod:gsub("%.init$", "")
  return mod
end

--- Block (tests only) until `task` settles; returns its result and error.
--- Raises when it does not settle within `ms`.
---@param task gg.Task
---@param ms? integer default 2000
---@return any result
---@return gg.Error|nil err
function H.await(task, ms)
  ms = ms or 2000
  local done, res, err = false, nil, nil
  task:on_done(function(r, e)
    done, res, err = true, r, e
  end)
  if not vim.wait(ms, function()
    return done
  end, 2) then
    error(("task did not settle within %d ms"):format(ms), 2)
  end
  return res, err
end

--- Let scheduled callbacks run for `ms` milliseconds (tests only).
---@param ms? integer default 20
function H.flush(ms)
  vim.wait(ms or 20, function()
    return false
  end, 2)
end

--- Wait (tests only) until `cond()` is true; raises after `ms`.
---@param cond fun(): boolean
---@param ms? integer default 2000
function H.wait_for(cond, ms)
  ms = ms or 2000
  if not vim.wait(ms, cond, 2) then
    error(("condition not met within %d ms"):format(ms), 2)
  end
end

H.TEST_HOST = "gitlab.example.com"
-- A fake token (not a GitLab token format) used to prove redaction.
H.TEST_TOKEN = "test-token-not-real-0001"

--- Configure gg with the fake backend and load fixture files (relative to
--- tests/fixtures). Retries are off unless `opts.retry` is given.
---@param files? string[]
---@param opts? { retry?: table, hosts?: table, log?: table }
---@return gg.FakeBackend
function H.fake(files, opts)
  opts = opts or {}
  local fake = require("gg.transport.backends.fake").new({ root = H.path("tests/fixtures") })
  for _, f in ipairs(files or {}) do
    fake:load(f)
  end
  local ok, err = require("gg.config").setup({
    hosts = opts.hosts or { [H.TEST_HOST] = { token = H.TEST_TOKEN } },
    transport = { backend = fake },
    retry = opts.retry or { max_attempts = 1 },
    log = opts.log or { level = "off" },
  })
  assert(ok, err and tostring(err))
  return fake
end

--- Reset gg's configuration to the defaults with logging off.
function H.reset()
  require("gg.config").setup({ log = { level = "off" } })
end

return H
