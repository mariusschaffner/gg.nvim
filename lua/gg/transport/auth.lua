--- Token lookup per host.
---
--- Order: the host's `token` in config (a string, or a function called per
--- request) -> the `GITLAB_TOKEN` environment variable, only for hosts listed
--- in `config.hosts` -> no token. Hosts that are not listed never get the env
--- token, so it cannot leak to a host parsed from an arbitrary remote URL.
local errors = require("gg.core.errors")

local M = {}

M.HEADER = "PRIVATE-TOKEN"
M.ENV = "GITLAB_TOKEN"

---@alias gg.TokenSource "config"|"function"|"env"|"none"

---@class gg.AuthResult
---@field token string|nil
---@field source gg.TokenSource
---@field err gg.Error|nil

local function env_token()
  local v = os.getenv(M.ENV)
  if v and v ~= "" then
    return v
  end
end

--- Where the token for a host would come from, without calling a token
--- function (used by health).
---@param settings gg.HostSettings
---@return gg.TokenSource
function M.source(settings)
  local t = settings.token
  if type(t) == "string" and t ~= "" then
    return "config"
  elseif type(t) == "function" then
    return "function"
  elseif settings.listed and env_token() then
    return "env"
  end
  return "none"
end

--- Resolve the token for a host.
---@param settings gg.HostSettings
---@return gg.AuthResult
function M.resolve(settings)
  local t = settings.token
  if type(t) == "string" and t ~= "" then
    return { token = t, source = "config" }
  end
  if type(t) == "function" then
    local ok, v = pcall(t)
    if not ok then
      return {
        source = "function",
        err = errors.new("auth", ("the token function for %s failed: %s"):format(settings.name, tostring(v)), {
          details = { host = settings.name },
        }),
      }
    end
    if type(v) ~= "string" or v == "" then
      return {
        source = "function",
        err = errors.new("auth", ("the token function for %s returned no token"):format(settings.name), {
          details = { host = settings.name },
        }),
      }
    end
    return { token = v, source = "function" }
  end
  if settings.listed then
    local v = env_token()
    if v then
      return { token = v, source = "env" }
    end
  end
  return { source = "none" }
end

--- Credential headers for a resolved token (empty when there is none).
---@param result gg.AuthResult
---@return table<string, string>|nil
function M.headers(result)
  if result.token then
    return { [M.HEADER] = result.token }
  end
  return nil
end

--- A hint for a 401, naming the host and where a token can be configured.
---@param settings gg.HostSettings
---@param result gg.AuthResult
---@return string
function M.hint(settings, result)
  if result.source == "none" then
    if settings.listed then
      return ("no token configured for %s (set hosts[%q].token or %s)"):format(settings.name, settings.name, M.ENV)
    end
    return ("no token for %s: the host is not listed in config.hosts, so %s is not used for it"):format(settings.name, M.ENV)
  end
  return ("the token for %s (from %s) was rejected"):format(settings.name, result.source)
end

return M
