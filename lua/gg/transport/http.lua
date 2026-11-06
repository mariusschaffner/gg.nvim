--- The request pipeline: host settings -> headers -> backend -> redirects.
---
--- Backend-agnostic: the curl backend in production, the fake backend in
--- tests (or any table with `send`). Redirects are followed here, manually, so
--- credentials are only ever sent to the configured instance's origin.
local config = require("gg.config")
local errors = require("gg.core.errors")
local log = require("gg.core.log")
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

return M
