--- The request pipeline: host settings -> headers -> backend -> redirects.
---
--- Backend-agnostic: the curl backend in production, the fake backend in
--- tests (or any table with `send`). Redirects are followed here, manually, so
--- credentials are only ever sent to the configured instance's origin.
local auth = require("gg.transport.auth")
local config = require("gg.config")
local errors = require("gg.core.errors")
local log = require("gg.core.log")
local ratelimit = require("gg.transport.ratelimit")
local task = require("gg.core.task")

local M = {}

M.MAX_REDIRECTS = 5

---@class gg.HttpRequest
---@field host string configured host name (required)
---@field method? string default "GET"
---@field url string absolute URL
---@field headers? table<string, string>
---@field credentials? table<string, string> headers sent only to the host's own origin (the token)
---@field body? string raw body
---@field output? string stream a 2xx body to this file
---@field on_chunk? fun(data: string) stream a 2xx body to this callback
---@field timeout? gg.TimeoutConfig partial override

---@class gg.Response
---@field status integer
---@field headers table<string, string>
---@field body string|nil raw body (nil when streamed)
---@field bytes integer|nil bytes streamed
---@field url string final URL (after redirects)

local REDIRECTS = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }
local DEFAULT_PORTS = { http = "80", https = "443" }

--- Origin of a URL: lowercase "scheme://host[:port]", default ports removed.
---@param url string
---@return string|nil
function M.origin(url)
  local scheme, authority = tostring(url):match("^(%a[%w+%.%-]*)://([^/?#]*)")
  if not scheme then
    return nil
  end
  scheme = scheme:lower()
  authority = authority:gsub("^.*@", ""):lower()
  local hostpart, port = authority:match("^(.*):(%d+)$")
  if hostpart and DEFAULT_PORTS[scheme] == port then
    authority = hostpart
  end
  return scheme .. "://" .. authority
end

--- Resolve a Location header against the URL it came from.
---@param base string
---@param location string
---@return string
function M.resolve_location(base, location)
  if location:match("^%a[%w+%.%-]*://") then
    return location
  end
  if location:sub(1, 2) == "//" then
    return base:match("^(%a[%w+%.%-]*:)") .. location
  end
  local root = base:match("^(%a[%w+%.%-]*://[^/?#]*)") or ""
  if location:sub(1, 1) == "/" then
    return root .. location
  end
  local path = base:sub(#root + 1):gsub("[?#].*$", "")
  local dir = path:match("^(.*/)") or "/"
  return root .. dir .. location
end

--- Strip the query string and fragment from a URL (for logs).
---@param url string
---@return string
function M.log_url(url)
  return (tostring(url):gsub("[?#].*$", ""))
end

local function resolve_backend()
  local b = config.backend()
  if b == "curl" or b == nil then
    return require("gg.transport.backends.curl")
  end
  return b
end

local function validate(opts)
  if type(opts) ~= "table" then
    return "request options must be a table"
  end
  if type(opts.host) ~= "string" then
    return "request.host is required"
  end
  if type(opts.url) ~= "string" or not opts.url:match("^[hH][tT][tT][pP][sS]?://") then
    return "request.url must be an absolute http(s) URL"
  end
  for _, t in ipairs({ opts.headers or {}, opts.credentials or {} }) do
    for k, v in pairs(t) do
      if type(k) ~= "string" or type(v) ~= "string" or k:find("[\r\n:]") or v:find("[\r\n]") then
        return "request headers must be single-line strings"
      end
    end
  end
  if opts.body ~= nil and type(opts.body) ~= "string" then
    return "request.body must be a string"
  end
  if opts.output ~= nil and opts.on_chunk ~= nil then
    return "request.output and request.on_chunk are mutually exclusive"
  end
  return nil
end

--- Send one HTTP request, following redirects. Resolves with a `gg.Response`
--- for any HTTP status; rejects only when no response was received.
---@param opts gg.HttpRequest
---@param secrets? string[] exact secrets for redaction (the token)
---@return gg.Task
function M.send(opts, secrets)
  local verr = validate(opts)
  if verr then
    return task.failed(errors.new("validation", verr))
  end
  local settings, herr = config.host(opts.host)
  if not settings then
    return task.failed(herr)
  end
  local backend = resolve_backend()
  local base_origin = M.origin(settings.base_url)
  local stream = opts.output ~= nil or opts.on_chunk ~= nil
  local timeout = vim.tbl_extend("force", settings.timeout, stream and { total = 0 } or {}, opts.timeout or {})

  return task.new(function(resolve, reject, on_cancel)
    local cancel_current
    on_cancel(function()
      if cancel_current then
        cancel_current()
      end
    end)

    local function attempt(url, method, body, hops)
      local headers = vim.deepcopy(opts.headers or {})
      if opts.credentials and M.origin(url) == base_origin then
        for k, v in pairs(opts.credentials) do
          headers[k] = v
        end
      end
      local req = {
        method = method,
        url = url,
        headers = headers,
        body = body,
        timeout = timeout,
        output = opts.output,
        on_chunk = opts.on_chunk,
        secrets = secrets,
        curl_cmd = config.curl_cmd(),
      }
      local started = vim.uv.hrtime()
      local settled = false
      local ok, cancel = pcall(backend.send, req, function(res, err)
        settled = true
        cancel_current = nil
        if err then
          log.debug("http request failed", function()
            return { method = method, url = M.log_url(url), kind = err.kind }
          end)
          return reject(err)
        end
        log.debug("http response", function()
          return {
            method = method,
            url = M.log_url(url),
            status = res.status,
            ms = math.floor((vim.uv.hrtime() - started) / 1e6),
          }
        end)
        local location = res.headers and res.headers["location"]
        if REDIRECTS[res.status] and location then
          if hops >= M.MAX_REDIRECTS then
            return reject(errors.new("network", ("too many redirects (more than %d)"):format(M.MAX_REDIRECTS), {
              status = res.status,
              details = { url = M.log_url(url) },
              secrets = secrets,
            }))
          end
          local next_url = M.resolve_location(url, location)
          local keep = res.status == 307 or res.status == 308
          return attempt(next_url, keep and method or "GET", keep and body or nil, hops + 1)
        end
        res.url = url
        resolve(res)
      end)
      if not ok then
        return reject(errors.new("unknown", "backend failed: " .. tostring(cancel), { secrets = secrets }))
      end
      if not settled then
        cancel_current = cancel
      end
    end

    attempt(opts.url, (opts.method or "GET"):upper(), opts.body, 0)
  end)
end

-- HTTP status -> error kind (open question 4 in docs/refactor/PLAN.md).
M.STATUS_KINDS = {
  [400] = "validation",
  [401] = "auth",
  [403] = "forbidden",
  [404] = "not_found",
  [405] = "validation",
  [406] = "validation",
  [409] = "validation",
  [410] = "not_found",
  [412] = "validation",
  [413] = "validation",
  [415] = "validation",
  [422] = "validation",
  [429] = "rate_limited",
}

local REASONS = {
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [406] = "Not Acceptable",
  [409] = "Conflict",
  [410] = "Gone",
  [412] = "Precondition Failed",
  [413] = "Payload Too Large",
  [415] = "Unsupported Media Type",
  [422] = "Unprocessable Entity",
  [429] = "Too Many Requests",
  [500] = "Internal Server Error",
  [502] = "Bad Gateway",
  [503] = "Service Unavailable",
  [504] = "Gateway Timeout",
}

M.ERROR_BODY_LIMIT = 2048

--- Decode a JSON body. Empty bodies decode to nil. JSON `null` becomes nil.
---@param body string|nil
---@return any value
---@return gg.Error|nil err kind "unknown" when the body is not JSON
function M.decode_json(body)
  if body == nil or body:match("^%s*$") then
    return nil, nil
  end
  local ok, value = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if not ok then
    return nil, errors.new("unknown", "invalid JSON in response", { details = { body = body:sub(1, M.ERROR_BODY_LIMIT) } })
  end
  return value, nil
end

-- "title" = { "can't be blank" } -> "title can't be blank"
local function field_messages(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = t[k]
    if type(v) == "table" then
      local msgs = {}
      for _, m in ipairs(v) do
        table.insert(msgs, tostring(m))
      end
      if #msgs == 0 then
        table.insert(parts, tostring(k) .. " " .. vim.inspect(v, { newline = " ", indent = "" }))
      else
        table.insert(parts, tostring(k) .. " " .. table.concat(msgs, ", "))
      end
    else
      table.insert(parts, tostring(k) .. " " .. tostring(v))
    end
  end
  return table.concat(parts, "; ")
end

--- The human-readable message GitLab put in an error body.
---@param decoded any decoded JSON body
---@param raw string|nil raw body
---@return string|nil
function M.body_message(decoded, raw)
  if type(decoded) == "table" then
    local m = decoded.message
    if type(m) == "string" and m ~= "" then
      return m
    elseif type(m) == "table" then
      if vim.islist(m) then
        local parts = {}
        for _, x in ipairs(m) do
          table.insert(parts, tostring(x))
        end
        return table.concat(parts, "; ")
      end
      return field_messages(m)
    end
    if type(decoded.error) == "string" then
      if type(decoded.error_description) == "string" then
        return decoded.error .. ": " .. decoded.error_description
      end
      return decoded.error
    end
    if type(decoded.errors) == "table" then
      local parts = {}
      for _, e in ipairs(decoded.errors) do
        table.insert(parts, type(e) == "table" and tostring(e.message or vim.inspect(e)) or tostring(e))
      end
      if #parts > 0 then
        return table.concat(parts, "; ")
      end
    end
  end
  if type(raw) == "string" and raw ~= "" and not raw:match("^%s*[<{%[]") then
    local line = raw:gsub("%s+", " "):sub(1, 200)
    return line
  end
  return nil
end

--- Build the error for a non-success response, or nil for 1xx/2xx/3xx.
---@param res gg.Response
---@param ctx { method: string, host: string, secrets?: string[], hint?: string }
---@return gg.Error|nil
function M.status_error(res, ctx)
  local status = res.status or 0
  if status >= 100 and status < 400 then
    return nil
  end
  local kind = M.STATUS_KINDS[status] or "unknown"
  local decoded = M.decode_json(res.body)
  local reason = ("%d %s"):format(status, REASONS[status] or "Error")
  local msg = M.body_message(decoded, res.body)
  local message
  if not msg then
    message = reason
  elseif msg:match("^" .. status) then
    message = msg
  else
    message = reason .. ": " .. msg
  end
  if ctx.hint then
    message = message .. " (" .. ctx.hint .. ")"
  end
  local headers = res.headers or {}
  local details = {
    method = ctx.method,
    url = M.log_url(res.url or ""),
    host = ctx.host,
    request_id = headers["x-request-id"],
  }
  if res.body and res.body ~= "" then
    details.body = res.body:sub(1, M.ERROR_BODY_LIMIT)
  end
  if status == 429 then
    details.retry_after = tonumber(headers["retry-after"])
  end
  return errors.new(kind, message, { status = status, details = details, secrets = ctx.secrets })
end

---@class gg.AuthedRequest : gg.HttpRequest
---@field auth? boolean default true: attach the host's token
---@field decode? "json"|"none" default "none": decode a 2xx body as JSON into `res.data`
---@field retry? gg.RetryConfig partial override of the host's retry policy
---@field clock? gg.Clock injectable time source (tests)

--- Send a request with the host's token attached. The token is passed as an
--- exact secret to redaction for everything this request produces.
---@param opts gg.AuthedRequest
---@return gg.Task resolves with gg.Response
function M.request(opts)
  if type(opts) ~= "table" then
    return task.failed(errors.new("validation", "request options must be a table"))
  end
  local settings, herr = config.host(opts.host)
  if not settings then
    return task.failed(herr)
  end
  local result = opts.auth == false and { source = "none" } or auth.resolve(settings)
  if result.err then
    return task.failed(result.err)
  end
  local secrets = result.token and { result.token } or {}
  local send_opts = {}
  for k, v in pairs(opts) do
    if k ~= "auth" and k ~= "credentials" and k ~= "decode" and k ~= "clock" and k ~= "retry" then
      send_opts[k] = v
    end
  end
  send_opts.credentials = auth.headers(result)
  local method = (opts.method or "GET"):upper()
  local clock = opts.clock or ratelimit.system_clock()
  local retry = vim.tbl_extend("force", settings.retry, opts.retry or {})
  local stream = opts.output ~= nil or opts.on_chunk ~= nil
  return task.run(function()
    local res, serr
    local attempt = 0
    while true do
      attempt = attempt + 1
      local err
      res, err = M.send(send_opts, secrets):await()
      local delay, why
      if err then
        delay, why = ratelimit.decide({ method = method, attempt = attempt, retry = retry, clock = clock, stream = stream }, nil, err)
        if not delay then
          if attempt > 1 then
            err.details = vim.tbl_extend("force", err.details or {}, { attempts = attempt })
          end
          return nil, errors.redact(err, secrets)
        end
      else
        res.rate_limit = ratelimit.parse(res.headers)
        if res.rate_limit then
          log.debug("rate limit", function()
            return { host = settings.name, remaining = res.rate_limit.remaining, limit = res.rate_limit.limit }
          end)
        end
        serr = M.status_error(res, {
          method = method,
          host = settings.name,
          secrets = secrets,
          hint = res.status == 401 and auth.hint(settings, result) or nil,
        })
        if not serr then
          break
        end
        delay, why = ratelimit.decide({ method = method, attempt = attempt, retry = retry, clock = clock, stream = stream }, res, nil)
        if not delay then
          if attempt > 1 or serr.kind == "rate_limited" then
            serr.details = vim.tbl_extend("force", serr.details or {}, { attempts = attempt, gave_up = why })
          end
          return nil, serr
        end
      end
      log.debug("retrying request", function()
        return { method = method, url = M.log_url(opts.url), attempt = attempt, delay_ms = delay }
      end)
      clock.sleep(delay):await()
    end
    if opts.decode == "json" and res.status >= 200 and res.status < 300 then
      local data, derr = M.decode_json(res.body)
      if derr then
        return nil, errors.redact(derr, secrets)
      end
      res.data = data
    end
    return res
  end)
end

return M
