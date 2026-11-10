--- Which GitLab project a picker shows.
---
--- `[host/]group/project` or a remote URL from the user, else the `origin`
--- remote of the working directory. This is the only module in gg that runs
--- `git` (asynchronously); the API layer never does. Besides the remote it
--- reads the current branch and pushes a branch, both for the creation
--- popups (`gg.ui.create`).
local gg = require("gg")

local M = {}

---@class gg.ui.Target
---@field host string configured host name
---@field project string full project path

local function invalid(message)
  return gg.errors.new("validation", message)
end

-- canonical host name for `name` (a configured host or one of its aliases)
local function configured_host(name, hosts)
  name = name:lower()
  for hname, h in pairs(hosts) do
    if hname:lower() == name then
      return hname:lower()
    end
    for _, alias in ipairs(h.aliases or {}) do
      if alias:lower() == name then
        return hname:lower()
      end
    end
  end
  return nil
end

local function from_url(url, hosts)
  local remote, err = gg.context.parse(url, { hosts = hosts })
  if not remote then
    return nil, invalid(("not a GitLab remote: %s (%s)"):format(url, err and err.message or "unknown"))
  end
  local _, herr = gg.config.host(remote.host)
  if herr then
    return nil, invalid(("host %s is not configured: add it to require(\"gg\").setup({ hosts = { ... } })"):format(remote.host))
  end
  return { host = remote.host, project = remote.project }, nil
end

--- Parse a user-given target: `group/project`, `host/group/project`, or a
--- remote URL. Pure apart from reading the configured hosts.
---@param arg string
---@param hosts? table<string, { aliases?: string[] }> default: gg.config.hosts()
---@return gg.ui.Target|nil
---@return gg.Error|nil
function M.parse(arg, hosts)
  hosts = hosts or gg.config.hosts()
  arg = vim.trim(arg or "")
  if arg == "" then
    return nil, invalid("no project given")
  end
  if arg:find("://", 1, true) or arg:match("^[^/%s]+@[^/%s]+:") then
    return from_url(arg, hosts)
  end
  arg = arg:gsub("^/+", ""):gsub("/+$", ""):gsub("%.git$", "")
  local first, rest = arg:match("^([^/]+)/(.+)$")
  if not first then
    return nil, invalid(("not a project path: %s (expected group/project)"):format(arg))
  end
  -- "host/group/project": the first segment is a configured host (projects
  -- always have a namespace, so "host/x" is read as group "host")
  local host = configured_host(first, hosts)
  if host and rest:find("/", 1, true) then
    return { host = host, project = rest }, nil
  end
  local names = vim.tbl_keys(hosts)
  table.sort(names)
  if #names == 1 then
    return { host = names[1]:lower(), project = arg }, nil
  elseif #names == 0 then
    return nil, invalid('no GitLab host is configured: require("gg").setup({ hosts = { ... } })')
  end
  return nil, invalid(("several hosts are configured (%s): use host/group/project"):format(table.concat(names, ", ")))
end

--- Resolve the target: from `opts.arg` when given, else from
--- `git remote get-url origin` in `opts.cwd` (default: the current directory).
---@param opts? { arg?: string, cwd?: string }
---@return gg.Task resolves with gg.ui.Target
function M.resolve(opts)
  opts = opts or {}
  if opts.arg and vim.trim(opts.arg) ~= "" then
    local target, err = M.parse(opts.arg)
    return target and gg.task.resolved(target) or gg.task.failed(err)
  end
  local cwd = opts.cwd or vim.fn.getcwd()
  return gg.task.new(function(resolve, reject, on_cancel)
    local ok, proc = pcall(vim.system, { "git", "remote", "get-url", "origin" }, { cwd = cwd, text = true }, function(res)
      vim.schedule(function()
        if res.code ~= 0 then
          reject(invalid(("no project given and no git remote \"origin\" in %s: use :Gitlab group/project"):format(cwd)))
          return
        end
        local target, err = from_url(vim.trim(res.stdout or ""), gg.config.hosts())
        if target then
          resolve(target)
        else
          reject(err)
        end
      end)
    end)
    if not ok then
      reject(invalid("could not run git: " .. tostring(proc) .. " (use :Gitlab group/project)"))
      return
    end
    on_cancel(function()
      pcall(proc.kill, proc, 15)
    end)
  end)
end

-- run git asynchronously; resolves with { code, stdout, stderr } (trimmed)
local function git(args, cwd)
  cwd = cwd or vim.fn.getcwd()
  return gg.task.new(function(resolve, reject, on_cancel)
    local argv = { "git" }
    vim.list_extend(argv, args)
    local ok, proc = pcall(vim.system, argv, { cwd = cwd, text = true }, function(res)
      vim.schedule(function()
        resolve({ code = res.code, stdout = vim.trim(res.stdout or ""), stderr = vim.trim(res.stderr or "") })
      end)
    end)
    if not ok then
      reject(invalid("could not run git: " .. tostring(proc)))
      return
    end
    on_cancel(function()
      pcall(proc.kill, proc, 15)
    end)
  end)
end

--- The branch checked out in `cwd` (default: the current directory):
--- `git branch --show-current`. Resolves with its name, or `false` outside a
--- repository and on a detached HEAD. Never fails for those.
---@param cwd? string
---@return gg.Task resolves with string|false
function M.current_branch(cwd)
  return gg.task.run(function()
    local res = git({ "branch", "--show-current" }, cwd):await()
    if not res or res.code ~= 0 or res.stdout == "" then
      return false
    end
    return res.stdout
  end)
end

--- Push `branch` to `origin` and track it: `git push -u origin <branch>`.
--- Resolves with true; fails with git's message.
---@param branch string
---@param cwd? string
---@return gg.Task
function M.push(branch, cwd)
  if type(branch) ~= "string" or branch == "" or branch:sub(1, 1) == "-" then
    return gg.task.failed(invalid("not a branch name: " .. tostring(branch)))
  end
  return gg.task.run(function()
    local res, err = git({ "push", "-u", "origin", branch }, cwd):await()
    if not res then
      return nil, err
    end
    if res.code ~= 0 then
      local msg = res.stderr ~= "" and res.stderr or ("git push exited with code %d"):format(res.code)
      return nil, gg.errors.new("unknown", "git push failed: " .. msg)
    end
    return true
  end)
end

return M
