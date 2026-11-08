--- Configuration: defaults, schema and validation.
---
--- The configuration is the only module-level state in gg ("configured
--- defaults"). Per-host settings are looked up explicitly on every call; there
--- is no "current host".
local errors = require("gg.core.errors")
local log = require("gg.core.log")

local M = {}

---@class gg.TimeoutConfig
---@field connect number seconds to establish a connection (0 = curl default)
---@field total number seconds for the whole request (0 = no limit)
---@field stall number seconds without progress before a streaming request fails (0 = never)

---@class gg.RetryConfig
---@field max_attempts integer total attempts, including the first
---@field base_delay_ms integer first backoff delay
---@field max_delay_ms integer cap for one backoff delay
---@field max_retry_after_s number cap for a server-requested wait (Retry-After)

---@class gg.HostConfig
---@field base_url? string e.g. "https://gitlab.example.com" or "https://example.com/gitlab"
---@field token? string|fun(): string personal access token, or a function returning one
---@field aliases? string[] other host names for the same instance (e.g. an SSH host)
---@field timeout? gg.TimeoutConfig partial override
---@field retry? gg.RetryConfig partial override

---@class gg.Backend
---@field send fun(req: gg.BackendRequest, on_done: fun(res: gg.BackendResponse|nil, err: gg.Error|nil)): fun()|nil

---@class gg.Config
---@field hosts table<string, gg.HostConfig|false>
---@field timeout gg.TimeoutConfig
---@field retry gg.RetryConfig
---@field curl { cmd: string }
---@field transport { backend: "curl"|gg.Backend }
---@field log { level: gg.LogLevel, sink?: gg.LogSink, file?: string }

---@class gg.HostSettings
---@field name string canonical host name (lowercase, no port)
---@field base_url string without trailing slash
---@field token string|fun(): string|nil
---@field listed boolean true when the host is in `config.hosts`
---@field timeout gg.TimeoutConfig
---@field retry gg.RetryConfig

local DEFAULTS = {
  -- no default instance: users list their GitLab host(s)
  hosts = {},
  timeout = { connect = 10, total = 60, stall = 30 },
  retry = { max_attempts = 3, base_delay_ms = 500, max_delay_ms = 30000, max_retry_after_s = 60 },
  curl = { cmd = "curl" },
  transport = { backend = "curl" },
  log = { level = "warn" },
}

local TOP_KEYS = { hosts = true, timeout = true, retry = true, curl = true, transport = true, log = true }
local HOST_KEYS = { base_url = true, token = true, aliases = true, timeout = true, retry = true }
local TIMEOUT_KEYS = { connect = true, total = true, stall = true }
local RETRY_KEYS = { max_attempts = true, base_delay_ms = true, max_delay_ms = true, max_retry_after_s = true }

local function fail(key, msg)
  return errors.new("validation", ("config.%s: %s"):format(key, msg), { details = { key = key } })
end

local function check_keys(tbl, allowed, prefix)
  for k in pairs(tbl) do
    if not allowed[k] then
      return fail(prefix .. "." .. tostring(k), "unknown option")
    end
  end
end

local function check_number(v, key, min, integer)
  if v == nil then
    return nil
  end
  if type(v) ~= "number" or v < min or (integer and math.floor(v) ~= v) then
    return fail(key, ("must be %s >= %s, got %s"):format(integer and "an integer" or "a number", min, type(v)))
  end
end

local function check_timeout(t, key)
  if t == nil then
    return nil
  end
  if type(t) ~= "table" then
    return fail(key, "must be a table")
  end
  local err = check_keys(t, TIMEOUT_KEYS, key)
  if err then
    return err
  end
  for k in pairs(TIMEOUT_KEYS) do
    err = check_number(t[k], key .. "." .. k, 0, false)
    if err then
      return err
    end
  end
end

local function check_retry(t, key)
  if t == nil then
    return nil
  end
  if type(t) ~= "table" then
    return fail(key, "must be a table")
  end
  local err = check_keys(t, RETRY_KEYS, key)
  if err then
    return err
  end
  err = check_number(t.max_attempts, key .. ".max_attempts", 1, true)
    or check_number(t.base_delay_ms, key .. ".base_delay_ms", 0, true)
    or check_number(t.max_delay_ms, key .. ".max_delay_ms", 0, true)
    or check_number(t.max_retry_after_s, key .. ".max_retry_after_s", 0, false)
  return err
end

--- True when `name` is a bare host name (no scheme, path or port).
---@param name any
---@return boolean
function M.is_host_name(name)
  if type(name) ~= "string" or name == "" then
    return false
  end
  return name:match("^[%w][%w%.%-]*$") ~= nil or name:match("^%[[%x:%.]+%]$") ~= nil
end

local function check_host(name, h)
  local key = "hosts." .. tostring(name)
  if not M.is_host_name(name) then
    return fail(key, "host names must be bare names like gitlab.example.com (no scheme, path or port)")
  end
  if h == false then
    return nil
  end
  if type(h) ~= "table" then
    return fail(key, "must be a table or false")
  end
  local err = check_keys(h, HOST_KEYS, key)
  if err then
    return err
  end
  if h.base_url ~= nil then
    if type(h.base_url) ~= "string" or not h.base_url:match("^[hH][tT][tT][pP][sS]?://[^/%s]+") then
      return fail(key .. ".base_url", "must be an http(s) URL")
    end
  end
  if h.token ~= nil and type(h.token) ~= "string" and type(h.token) ~= "function" then
    return fail(key .. ".token", ("must be a string or a function, got %s"):format(type(h.token)))
  end
  if h.aliases ~= nil then
    if type(h.aliases) ~= "table" then
      return fail(key .. ".aliases", "must be a list of host names")
    end
    for i, a in ipairs(h.aliases) do
      if not M.is_host_name(a) then
        return fail(("%s.aliases[%d]"):format(key, i), "must be a bare host name")
      end
    end
  end
  return check_timeout(h.timeout, key .. ".timeout") or check_retry(h.retry, key .. ".retry")
end

--- Validate a user config table without applying it.
---@param opts any
---@return gg.Error|nil
function M.validate(opts)
  if opts == nil then
    return nil
  end
  if type(opts) ~= "table" then
    return fail("(root)", "setup() expects a table")
  end
  local err = check_keys(opts, TOP_KEYS, "")
  if err then
    -- strip the leading dot of the root prefix
    err.message = err.message:gsub("^config%.%.", "config.")
    err.details.key = err.details.key:gsub("^%.", "")
    return err
  end
  if opts.hosts ~= nil then
    if type(opts.hosts) ~= "table" then
      return fail("hosts", "must be a table of host name -> settings")
    end
    for name, h in pairs(opts.hosts) do
      err = check_host(name, h)
      if err then
        return err
      end
    end
  end
  err = check_timeout(opts.timeout, "timeout") or check_retry(opts.retry, "retry")
  if err then
    return err
  end
  if opts.curl ~= nil then
    if type(opts.curl) ~= "table" then
      return fail("curl", "must be a table")
    end
    err = check_keys(opts.curl, { cmd = true }, "curl")
    if err then
      return err
    end
    if opts.curl.cmd ~= nil and (type(opts.curl.cmd) ~= "string" or opts.curl.cmd == "") then
      return fail("curl.cmd", "must be a non-empty string")
    end
  end
  if opts.transport ~= nil then
    if type(opts.transport) ~= "table" then
      return fail("transport", "must be a table")
    end
    err = check_keys(opts.transport, { backend = true }, "transport")
    if err then
      return err
    end
    local b = opts.transport.backend
    if b ~= nil and b ~= "curl" and not (type(b) == "table" and type(b.send) == "function") then
      return fail("transport.backend", 'must be "curl" or a backend table with a send() function')
    end
  end
  if opts.log ~= nil then
    if type(opts.log) ~= "table" then
      return fail("log", "must be a table")
    end
    err = check_keys(opts.log, { level = true, sink = true, file = true }, "log")
    if err then
      return err
    end
    if opts.log.level ~= nil and log.LEVELS[opts.log.level] == nil then
      return fail("log.level", "must be one of trace, debug, info, warn, error, off")
    end
    if opts.log.sink ~= nil and type(opts.log.sink) ~= "function" then
      return fail("log.sink", "must be a function")
    end
    if opts.log.file ~= nil and type(opts.log.file) ~= "string" then
      return fail("log.file", "must be a string")
    end
  end
  return nil
end

local function strip_slash(url)
  return (url:gsub("/+$", ""))
end

local function normalize(opts)
  local cfg = vim.deepcopy(DEFAULTS)
  opts = opts or {}
  cfg.timeout = vim.tbl_extend("force", cfg.timeout, opts.timeout or {})
  cfg.retry = vim.tbl_extend("force", cfg.retry, opts.retry or {})
  cfg.curl = vim.tbl_extend("force", cfg.curl, opts.curl or {})
  cfg.log = vim.tbl_extend("force", cfg.log, opts.log or {})
  cfg.transport = { backend = (opts.transport and opts.transport.backend) or "curl" }
  local hosts = {}
  for name, h in pairs(cfg.hosts) do
    hosts[name] = h
  end
  for name, h in pairs(opts.hosts or {}) do
    hosts[name:lower()] = h
  end
  cfg.hosts = {}
  for name, h in pairs(hosts) do
    if h ~= false then
      local copy = {}
      for k, v in pairs(h) do
        copy[k] = v
      end
      copy.base_url = strip_slash(copy.base_url or ("https://" .. name))
      local aliases = {}
      for _, a in ipairs(copy.aliases or {}) do
        table.insert(aliases, a:lower())
      end
      copy.aliases = aliases
      cfg.hosts[name] = copy
    end
  end
  return cfg
end

local state = normalize(nil)

--- Apply a configuration. On failure the previous configuration is kept.
---@param opts? table see gg.Config
---@return boolean ok
---@return gg.Error|nil err
function M.setup(opts)
  local err = M.validate(opts)
  if err then
    return false, err
  end
  local cfg = normalize(opts)
  local ok, log_err = log.configure(cfg.log)
  if not ok then
    return false, log_err
  end
  state = cfg
  return true, nil
end

--- A copy of the effective configuration (the transport backend is shared,
--- not copied).
---@return gg.Config
function M.get()
  local backend = state.transport.backend
  local copy = vim.deepcopy(state)
  copy.transport.backend = backend
  return copy
end

--- The configured transport backend: "curl" or a backend table.
---@return "curl"|gg.Backend
function M.backend()
  return state.transport.backend
end

--- The curl executable.
---@return string
function M.curl_cmd()
  return state.curl.cmd
end

--- Effective settings for a configured host. Aliases resolve to their host.
--- There is no default instance: a host that is not in `config.hosts` is a
--- `validation` error, so nothing is ever sent to an unconfigured host.
---@param name string
---@return gg.HostSettings|nil
---@return gg.Error|nil
function M.host(name)
  if not M.is_host_name(name) then
    return nil, errors.new("validation", "host must be a bare host name like gitlab.example.com", {
      details = { key = "host" },
    })
  end
  local lname = name:lower()
  local canonical, h = lname, state.hosts[lname]
  if not h then
    for hname, hcfg in pairs(state.hosts) do
      if vim.tbl_contains(hcfg.aliases or {}, lname) then
        canonical, h = hname, hcfg
        break
      end
    end
  end
  if not h then
    return nil, errors.new("validation", ("host %s is not configured; add it to hosts in gg.setup()"):format(lname), {
      details = { key = "host", host = lname },
    })
  end
  return {
    name = canonical,
    base_url = h.base_url,
    token = h.token,
    listed = true,
    timeout = vim.tbl_extend("force", state.timeout, h.timeout or {}),
    retry = vim.tbl_extend("force", state.retry, h.retry or {}),
  }, nil
end

--- The listed hosts, in the shape `gg.context.parse` accepts as `opts.hosts`.
---@return table<string, { base_url: string, aliases: string[] }>
function M.hosts()
  local out = {}
  for name, h in pairs(state.hosts) do
    out[name] = { base_url = h.base_url, aliases = vim.deepcopy(h.aliases or {}) }
  end
  return out
end

return M
