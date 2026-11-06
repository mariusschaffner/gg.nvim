--- A backend that replays recorded fixtures. Used by gg's own tests, and
--- usable by consumers' tests:
---
---   local fake = require("gg").testing.fake_backend.new({ root = "tests/fixtures" })
---   fake:load("rest/issues/list.json")
---   require("gg").setup({ transport = { backend = fake } })
---
--- Fixture format (one object, or an array of them for page sequences):
---   {
---     "meta":     { "source": "...", "notes": "..." },
---     "request":  { "method": "GET", "path": "/api/v4/...", "query": { ... } }
---              |  { "operation": "IssueGet", "variables": { ... } },
---     "response": { "status": 200, "headers": { ... }, "body": <json> | "<text>",
---                   "body_base64": "...", "delay": 0, "error": { "kind": "timeout" } },
---     "repeat":   false
---   }
---
--- Matching: REST by method + raw path + query (exact when `query` is given,
--- subset with `query_contains`, any when neither). GraphQL by operation name
--- + a subset of the variables. A fixture is used once unless `repeat` is true;
--- matching fixtures are served in the order they were loaded.
local errors = require("gg.core.errors")

local M = {}

---@class gg.FakeRecordedRequest
---@field method string
---@field url string
---@field path string raw (still percent-encoded) path
---@field query table<string, string|string[]> decoded query values
---@field headers table<string, string>
---@field body string|nil
---@field json any decoded JSON body, when the body is JSON
---@field operation string|nil GraphQL operation name
---@field variables table|nil GraphQL variables

---@class gg.FakeBackend : gg.Backend
---@field root string
---@field private _fixtures table[]
---@field private _requests gg.FakeRecordedRequest[]
local Fake = {}
Fake.__index = Fake

local function decode_component(s)
  s = s:gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- Split a URL into its raw path and decoded query table. Repeated keys and
--- `key[]` keys become lists.
---@param url string
---@return string path
---@return table<string, string|string[]> query
function M.parse_url(url)
  local rest = url:gsub("^%a[%w+%.%-]*://[^/?#]*", ""):gsub("#.*$", "")
  local path, q = rest:match("^([^?]*)%??(.*)$")
  local query = {}
  for pair in (q or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    k, v = decode_component(k), decode_component(v)
    local list = k:match("^(.-)%[%]$")
    if list then
      query[list] = query[list] or {}
      table.insert(query[list], v)
    elseif query[k] ~= nil then
      if type(query[k]) ~= "table" then
        query[k] = { query[k] }
      end
      table.insert(query[k], v)
    else
      query[k] = v
    end
  end
  return path ~= "" and path or "/", query
end

local function normalize_query_value(v)
  if type(v) == "table" then
    local out = {}
    for i, x in ipairs(v) do
      out[i] = tostring(x)
    end
    return out
  end
  return tostring(v)
end

-- deep subset: every key in `want` exists in `have` with an equal value
local function subset(want, have)
  if type(want) ~= "table" then
    if type(want) == "number" and type(have) == "string" then
      return tostring(want) == have
    end
    return want == have
  end
  if type(have) ~= "table" then
    return false
  end
  for k, v in pairs(want) do
    if not subset(v, have[k]) then
      return false
    end
  end
  return true
end

local function query_equal(want, have)
  local w = {}
  for k, v in pairs(want) do
    w[k] = normalize_query_value(v)
  end
  return vim.deep_equal(w, have)
end

local function query_subset(want, have)
  for k, v in pairs(want) do
    if not vim.deep_equal(normalize_query_value(v), have[k]) then
      return false
    end
  end
  return true
end

local function matches(fx, rec)
  local r = fx.request or {}
  if r.operation then
    return rec.operation == r.operation and (r.variables == nil or subset(r.variables, rec.variables or {}))
  end
  if rec.operation and not r.path then
    return false
  end
  if (r.method or "GET"):upper() ~= rec.method then
    return false
  end
  if r.path and r.path ~= rec.path then
    return false
  end
  if r.query and not query_equal(r.query, rec.query) then
    return false
  end
  if r.query_contains and not query_subset(r.query_contains, rec.query) then
    return false
  end
  if r.body_contains and not subset(r.body_contains, rec.json) then
    return false
  end
  return true
end

local function describe(rec)
  if rec.operation then
    return ("GraphQL %s %s"):format(rec.operation, vim.inspect(rec.variables or {}, { newline = " ", indent = "" }))
  end
  local keys = vim.tbl_keys(rec.query)
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    table.insert(parts, k .. "=" .. vim.inspect(rec.query[k], { newline = "", indent = "" }))
  end
  return ("%s %s%s"):format(rec.method, rec.path, #parts > 0 and ("?" .. table.concat(parts, "&")) or "")
end

local function describe_fixture(fx)
  local r = fx.request or {}
  if r.operation then
    return ("GraphQL %s %s"):format(r.operation, vim.inspect(r.variables or {}, { newline = " ", indent = "" }))
  end
  local q = r.query or r.query_contains
  local s = ("%s %s"):format((r.method or "GET"):upper(), r.path or "*")
  if q then
    s = s .. " " .. vim.inspect(q, { newline = " ", indent = "" })
  end
  return s
end

--- Create a fake backend.
---@param opts? { root?: string, chunk_size?: integer }
---@return gg.FakeBackend
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    root = opts.root or (vim.fn.getcwd() .. "/tests/fixtures"),
    chunk_size = opts.chunk_size or 4096,
    _fixtures = {},
    _requests = {},
  }, Fake)
  -- `send` is a plain function field so the instance satisfies gg.Backend
  self.send = function(req, cb)
    return self:_send(req, cb)
  end
  return self
end

--- Add fixtures (a fixture table or a list of them).
---@param fixtures table|table[]
---@return gg.FakeBackend self
function Fake:add(fixtures)
  if fixtures.request or fixtures.response then
    fixtures = { fixtures }
  end
  for _, fx in ipairs(fixtures) do
    table.insert(self._fixtures, vim.deepcopy(fx))
  end
  return self
end

--- Read a fixture file (relative to `root`, or absolute) and return its fixtures.
---@param path string
---@param root? string default "<cwd>/tests/fixtures"
---@return table[]
function M.read(path, root)
  local full = path
  if not path:match("^%a:[/\\]") and not path:match("^/") then
    full = (root or (vim.fn.getcwd() .. "/tests/fixtures")) .. "/" .. path
  end
  local f = io.open(full, "rb")
  if not f then
    error("fake: fixture not found: " .. full, 2)
  end
  local data = f:read("*a")
  f:close()
  local decoded = vim.json.decode(data, { luanil = { object = true, array = true } })
  if decoded.request or decoded.response then
    return { decoded }
  end
  return decoded
end

--- Load fixture files (relative to `root`).
---@param ... string
---@return gg.FakeBackend self
function Fake:load(...)
  for _, path in ipairs({ ... }) do
    self:add(M.read(path, self.root))
  end
  return self
end

--- Recorded requests, in order.
---@return gg.FakeRecordedRequest[]
function Fake:requests()
  return self._requests
end

--- The last recorded request.
---@return gg.FakeRecordedRequest|nil
function Fake:last()
  return self._requests[#self._requests]
end

--- Drop all fixtures and recorded requests.
---@return gg.FakeBackend self
function Fake:reset()
  self._fixtures = {}
  self._requests = {}
  return self
end

--- Fixtures that were never used (for "everything was requested" assertions).
---@return table[]
function Fake:unused()
  local out = {}
  for _, fx in ipairs(self._fixtures) do
    if not fx._used then
      table.insert(out, fx)
    end
  end
  return out
end

local function record(req)
  local path, query = M.parse_url(req.url)
  local rec = {
    method = (req.method or "GET"):upper(),
    url = req.url,
    path = path,
    query = query,
    headers = vim.deepcopy(req.headers or {}),
    body = req.body,
  }
  if req.body and req.body:match("^%s*[{%[]") then
    local ok, json = pcall(vim.json.decode, req.body, { luanil = { object = true, array = true } })
    if ok then
      rec.json = json
    end
  end
  if path:match("/api/graphql$") and type(rec.json) == "table" then
    rec.operation = rec.json.operationName
    rec.variables = rec.json.variables or {}
  end
  return rec
end

local function body_string(response)
  if response.body_base64 then
    return vim.base64.decode(response.body_base64)
  end
  local b = response.body
  if b == nil then
    return ""
  end
  if type(b) == "string" then
    return b
  end
  return vim.json.encode(b)
end

local function lower_headers(h)
  local out = {}
  for k, v in pairs(h or {}) do
    out[k:lower()] = tostring(v)
  end
  return out
end

---@private
function Fake:_send(req, cb)
  local rec = record(req)
  table.insert(self._requests, rec)
  local cancelled = false
  local function deliver(res, err)
    if not cancelled then
      cb(res, err)
    end
  end

  local chosen
  for _, fx in ipairs(self._fixtures) do
    if (fx["repeat"] or not fx._used) and matches(fx, rec) then
      chosen = fx
      break
    end
  end

  if not chosen then
    local near = {}
    for _, fx in ipairs(self._fixtures) do
      local r = fx.request or {}
      if (rec.operation and r.operation == rec.operation) or (not rec.operation and r.path == rec.path) then
        table.insert(near, describe_fixture(fx) .. (fx._used and " (used)" or ""))
      end
    end
    if #near == 0 then
      for i, fx in ipairs(self._fixtures) do
        if i > 8 then
          break
        end
        table.insert(near, describe_fixture(fx) .. (fx._used and " (used)" or ""))
      end
    end
    vim.schedule(function()
      deliver(nil, errors.new("unknown", "fake backend: no fixture for " .. describe(rec), {
        details = { request = describe(rec), candidates = near },
      }))
    end)
    return function()
      cancelled = true
    end
  end

  chosen._used = true
  local response = chosen.response or {}

  local function respond()
    if cancelled then
      return
    end
    if response.error then
      local e = response.error
      return deliver(nil, errors.new(e.kind or "network", e.message or ("fake " .. (e.kind or "network") .. " error")))
    end
    local status = response.status or 200
    local res = { status = status, headers = lower_headers(response.headers) }
    local body = body_string(response)
    local ok_status = status >= 200 and status < 300
    if req.output and ok_status then
      local f = io.open(req.output, "wb")
      if not f then
        return deliver(nil, errors.new("unknown", "fake backend: cannot write " .. req.output))
      end
      f:write(body)
      f:close()
      res.bytes = #body
      return deliver(res, nil)
    elseif req.on_chunk and ok_status then
      local size = self.chunk_size
      for i = 1, #body, size do
        req.on_chunk(body:sub(i, i + size - 1))
      end
      res.bytes = #body
      return deliver(res, nil)
    end
    res.body = body
    deliver(res, nil)
  end

  local delay = response.delay or 0
  if delay > 0 then
    vim.defer_fn(respond, delay)
  else
    vim.schedule(respond)
  end
  return function()
    cancelled = true
  end
end

return M
