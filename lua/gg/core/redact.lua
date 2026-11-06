--- Redaction of secrets in strings and nested values.
---
--- Used by errors and log so tokens never reach messages, details or log
--- output. Over-redaction is acceptable; leaking is not.
local M = {}

M.MASK = "[REDACTED]"

-- GitLab token prefixes (personal, OAuth, deploy, runner, CI build, trigger,
-- feed, incoming mail, agent, workspace, SCIM, feature-flag client).
local TOKEN_PREFIXES = {
  "glpat-", "gloas-", "gldt-", "glrt-", "glrtr-", "glcbt-", "glptt-", "glft-",
  "glimt-", "glagent-", "glwt-", "glsoat-", "glffct-", "gltst-",
}

-- Keys whose values are always secret (compared lowercased, with `_` as `-`).
local SECRET_KEYS = {
  ["token"] = true,
  ["private-token"] = true,
  ["job-token"] = true,
  ["access-token"] = true,
  ["refresh-token"] = true,
  ["authorization"] = true,
  ["password"] = true,
  ["secret"] = true,
  ["client-secret"] = true,
}

-- Build a case-insensitive Lua pattern for a literal word.
local function ci(word)
  return (word:gsub("%a", function(c)
    return "[" .. c:lower() .. c:upper() .. "]"
  end):gsub("%-", "%%-"))
end

local HEADER_NAMES = { "private-token", "job-token", "authorization", "proxy-authorization", "cookie", "set-cookie" }
local QUERY_KEYS = { "private_token", "job_token", "access_token", "refresh_token", "token", "password" }

local function escape_pattern(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

--- True when `key` names a secret (e.g. "token", "PRIVATE-TOKEN", "access_token").
---@param key any
---@return boolean
function M.is_secret_key(key)
  if type(key) ~= "string" then
    return false
  end
  return SECRET_KEYS[(key:lower():gsub("_", "-"))] == true
end

--- Redact secrets inside a string.
---@param s string
---@param secrets? string[] exact values to mask (e.g. the token used for a request)
---@return string
function M.string(s, secrets)
  if type(s) ~= "string" or s == "" then
    return s
  end
  -- exact secrets first, longest first so a prefix doesn't leave a tail
  if secrets and #secrets > 0 then
    local list = {}
    for _, v in ipairs(secrets) do
      if type(v) == "string" and #v >= 4 then
        table.insert(list, v)
      end
    end
    table.sort(list, function(a, b)
      return #a > #b
    end)
    for _, v in ipairs(list) do
      s = s:gsub(escape_pattern(v), M.MASK)
    end
  end
  -- GitLab tokens by prefix
  for _, prefix in ipairs(TOKEN_PREFIXES) do
    s = s:gsub(escape_pattern(prefix) .. "[%w_%-]+", M.MASK)
  end
  -- header lines: "PRIVATE-TOKEN: value", "Authorization: Bearer value"
  for _, name in ipairs(HEADER_NAMES) do
    s = s:gsub("(" .. ci(name) .. "%s*:%s*)[^\r\n]+", "%1" .. M.MASK)
  end
  -- curl config style: header = "PRIVATE-TOKEN: value" is covered above
  -- query parameters: ?private_token=value
  for _, key in ipairs(QUERY_KEYS) do
    s = s:gsub("([?&;]" .. ci(key) .. "=)[^&%s#\"']+", "%1" .. M.MASK)
  end
  -- JSON or Lua style "token": "value" / token = "value"
  s = s:gsub("([\"']?[%w_%-]*[Tt][Oo][Kk][Ee][Nn][\"']?%s*[:=]%s*[\"'])[^\"']*([\"'])", "%1" .. M.MASK .. "%2")
  s = s:gsub("([\"']?[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][\"']?%s*[:=]%s*[\"'])[^\"']*([\"'])", "%1" .. M.MASK .. "%2")
  -- URL userinfo: https://user:pass@host
  s = s:gsub("(%a[%w+%.%-]*://)[^/@%s\"']+@", "%1" .. M.MASK .. "@")
  return s
end

local function redact_value(v, secrets, seen)
  local t = type(v)
  if t == "string" then
    return M.string(v, secrets)
  elseif t ~= "table" then
    return v
  end
  if seen[v] then
    return seen[v]
  end
  local out = {}
  seen[v] = out
  for k, val in pairs(v) do
    local key = type(k) == "string" and M.string(k, secrets) or k
    if M.is_secret_key(k) and val ~= nil and type(val) ~= "table" and type(val) ~= "boolean" then
      out[key] = M.MASK
    else
      out[key] = redact_value(val, secrets, seen)
    end
  end
  local mt = getmetatable(v)
  if mt then
    setmetatable(out, mt)
  end
  return out
end

--- Deep-redact a value. Returns a copy; the input is not modified.
---@generic T
---@param v T
---@param secrets? string[] exact values to mask
---@return T
function M.value(v, secrets)
  return redact_value(v, secrets, {})
end

return M
