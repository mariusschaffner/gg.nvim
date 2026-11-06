--- REST client: `/api/v4` URLs, encoding, JSON, and single pages.
---
--- Project segments are always URL-encoded (`group/sub/repo` ->
--- `group%2Fsub%2Frepo`); numeric IDs pass through.
local config = require("gg.config")
local errors = require("gg.core.errors")
local http = require("gg.transport.http")
local pagination = require("gg.transport.pagination")
local task = require("gg.core.task")

local M = {}

M.API = "/api/v4"

---@class gg.RestResponse
---@field status integer
---@field headers table<string, string>
---@field data any decoded JSON (nil for empty bodies and streamed responses)
---@field bytes integer|nil bytes streamed
---@field url string
---@field rate_limit gg.RateLimit|nil

---@class gg.RestOptions
---@field query? table<string, any>
---@field body? table|string a table is sent as JSON
---@field headers? table<string, string>
---@field output? string stream a 2xx body to this file
---@field on_chunk? fun(data: string) stream a 2xx body to this callback
---@field timeout? gg.TimeoutConfig
---@field accept? string default "application/json"

--- Percent-encode everything except the unreserved characters `A-Za-z0-9-_.~`.
---@param s any
---@return string
function M.encode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

--- The URL segment for a project: a numeric ID, or a full path (encoded).
---@param project any integer ID, digit string, or "namespace/project" path
---@return string|nil segment
---@return gg.Error|nil
function M.project(project)
  if type(project) == "number" then
    if project >= 1 and math.floor(project) == project then
      return tostring(project), nil
    end
  elseif type(project) == "string" then
    if project:match("^%d+$") then
      return project, nil
    end
    local path = project:gsub("^/+", ""):gsub("/+$", "")
    if path:find("/", 1, true) and not path:find("//", 1, true) and not path:match("%s") then
      return M.encode(path), nil
    end
  end
  return nil, errors.new("validation", "project must be a numeric ID or a full path like group/project", {
    details = { key = "project" },
  })
end

--- Encode any other path segment (IDs, branch names, file paths).
---@param x string|integer
---@return string
function M.seg(x)
  return M.encode(x)
end

local function query_value(v)
  if type(v) == "boolean" then
    return v and "true" or "false"
  end
  return tostring(v)
end

--- Build a query string: keys and values encoded, keys sorted, list values as
--- `key[]=v` (GitLab's array syntax). nil and vim.NIL values are skipped.
---@param t table<string, any>|nil
---@return string without the leading "?"
function M.query(t)
  if not t then
    return ""
  end
  local keys = {}
  for k, v in pairs(t) do
    if v ~= nil and v ~= vim.NIL then
      table.insert(keys, tostring(k))
    end
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = t[k]
    if type(v) == "table" then
      for _, x in ipairs(v) do
        table.insert(parts, M.encode(k .. "[]") .. "=" .. M.encode(query_value(x)))
      end
    else
      table.insert(parts, M.encode(k) .. "=" .. M.encode(query_value(v)))
    end
  end
  return table.concat(parts, "&")
end

--- Full URL for an API path on a host.
---@param host string
---@param path string starting with "/"
---@param query? table
---@return string|nil url
---@return gg.Error|nil
function M.url(host, path, query)
  local settings, err = config.host(host)
  if not settings then
    return nil, err
  end
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" then
    return nil, errors.new("validation", "API path must start with /")
  end
  local q = M.query(query)
  return settings.base_url .. M.API .. path .. (q ~= "" and ("?" .. q) or ""), nil
end

local function body_string(body)
  if body == nil then
    return nil
  end
  if type(body) == "string" then
    return body
  end
  return vim.json.encode(body)
end

--- Send a REST request. Resolves with a `gg.RestResponse`.
---@param host string
---@param method "GET"|"POST"|"PUT"|"DELETE"|"PATCH"
---@param path string API path starting with "/" (segments already encoded)
---@param opts? gg.RestOptions
---@return gg.Task
function M.request(host, method, path, opts)
  opts = opts or {}
  local url, err = M.url(host, path, opts.query)
  if not url then
    return task.failed(err)
  end
  return M.request_url(host, method, url, opts)
end

--- Send a REST request to an absolute URL on the host (e.g. a keyset link).
---@param host string
---@param method string
---@param url string
---@param opts? gg.RestOptions
---@return gg.Task
function M.request_url(host, method, url, opts)
  opts = opts or {}
  local stream = opts.output ~= nil or opts.on_chunk ~= nil
  local headers = { Accept = opts.accept or (stream and "*/*" or "application/json") }
  local body = body_string(opts.body)
  if body ~= nil then
    headers["Content-Type"] = type(opts.body) == "string" and "text/plain" or "application/json"
  end
  for k, v in pairs(opts.headers or {}) do
    headers[k] = v
  end
  return task.run(function()
    local res, err = http.request({
      host = host,
      method = method,
      url = url,
      headers = headers,
      body = body,
      output = opts.output,
      on_chunk = opts.on_chunk,
      timeout = opts.timeout,
      decode = stream and "none" or "json",
    }):await()
    if err then
      return nil, err
    end
    return {
      status = res.status,
      headers = res.headers,
      data = res.data,
      bytes = res.bytes,
      url = res.url,
      rate_limit = res.rate_limit,
    }
  end)
end

--- GET and resolve with the decoded body.
---@param host string
---@param path string
---@param opts? gg.RestOptions
---@return gg.Task
function M.get(host, path, opts)
  return task.run(function()
    local res, err = M.request(host, "GET", path, opts):await()
    if err then
      return nil, err
    end
    return res.data
  end)
end

---@class gg.RestPageOptions
---@field query? table<string, any>
---@field per_page? integer
---@field default_per_page? integer
---@field cursor? string
---@field pagination? "offset"|"keyset"

--- Fetch one page of a REST list. Resolves with `gg.Page` of raw items.
---@param host string
---@param path string
---@param opts? gg.RestPageOptions
---@return gg.Task
function M.page(host, path, opts)
  opts = opts or {}
  local settings, serr = config.host(host)
  if not settings then
    return task.failed(serr)
  end
  local mode = opts.pagination or "offset"
  local c, cerr = pagination.rest_cursor(opts.cursor, http.origin(settings.base_url), http.origin)
  if not c then
    return task.failed(cerr)
  end
  local per_page = pagination.per_page(opts.per_page, opts.default_per_page)
  return task.run(function()
    local res, err
    if c.url then
      res, err = M.request_url(host, "GET", c.url, {}):await()
    else
      local query = vim.deepcopy(opts.query or {})
      query.per_page = per_page
      if mode == "keyset" then
        query.pagination = "keyset"
      else
        query.page = c.page
      end
      res, err = M.request(host, "GET", path, { query = query }):await()
    end
    if err then
      return nil, err
    end
    local items = res.data
    if items == nil then
      items = {}
    end
    if type(items) ~= "table" or (next(items) ~= nil and not vim.islist(items)) then
      return nil, errors.new("unknown", "expected a JSON list from " .. path)
    end
    return { items = items, next_cursor = pagination.rest_next(res.headers, mode) }
  end)
end

return M
