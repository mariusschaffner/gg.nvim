--- GraphQL client. Queries live in `queries/<name>.graphql`; the operation in
--- the file must be named after the file in PascalCase (issue_get -> IssueGet).
---
--- Errors: an HTTP 200 with a non-empty `errors` array is a `graphql` error.
--- When `data` came back as well, it is attached as `details.partial`; it is
--- never dropped and never returned as success. Resources that can use
--- partial data must do so explicitly.
local config = require("gg.config")
local errors = require("gg.core.errors")
local http = require("gg.transport.http")
local pagination = require("gg.transport.pagination")
local task = require("gg.core.task")

local M = {}

M.ENDPOINT = "/api/graphql"

local QUERY_DIR = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "queries")

-- Query texts, read once. Immutable constants (the files never change at runtime).
local texts = {}

--- PascalCase operation name for a query file name.
---@param name string e.g. "issue_get"
---@return string e.g. "IssueGet"
function M.operation_name(name)
  return (name:gsub("^%l", string.upper):gsub("_(%w)", function(c)
    return c:upper()
  end))
end

--- Directory holding the `.graphql` files.
---@return string
function M.query_dir()
  return QUERY_DIR
end

--- Load a query file. Never throws.
---@param name string query file name (without .graphql)
---@return string|nil text
---@return gg.Error|nil
function M.load(name)
  if type(name) ~= "string" or not name:match("^[%w_]+$") then
    return nil, errors.new("validation", "invalid GraphQL query name", { details = { name = tostring(name) } })
  end
  if texts[name] then
    return texts[name], nil
  end
  local path = vim.fs.joinpath(QUERY_DIR, name .. ".graphql")
  local f = io.open(path, "rb")
  if not f then
    return nil, errors.new("validation", "unknown GraphQL query: " .. name, { details = { name = name } })
  end
  local text = f:read("*a")
  f:close()
  local op = M.operation_name(name)
  if not text:match("%f[%w](query)%s+" .. op .. "%f[^%w]") and not text:match("%f[%w](mutation)%s+" .. op .. "%f[^%w]") then
    return nil, errors.new("validation", ("query file %s.graphql must define the operation %s"):format(name, op), {
      details = { name = name },
    })
  end
  texts[name] = text
  return text, nil
end

--- Messages of a GraphQL `errors` array, for error messages.
---@param list table
---@return string
local function summarize(list)
  local first = list[1]
  local msg = type(first) == "table" and tostring(first.message or "GraphQL error") or tostring(first)
  if #list > 1 then
    msg = ("%s (and %d more)"):format(msg, #list - 1)
  end
  return msg
end

local function normalize_errors(list)
  local out = {}
  for i, e in ipairs(list) do
    if type(e) == "table" then
      out[i] = { message = e.message, path = e.path, extensions = e.extensions, locations = e.locations }
    else
      out[i] = { message = tostring(e) }
    end
  end
  return out
end

---@alias gg.GraphqlQueryRef string|{ operation: string, text: string }

-- A query file name, or an inline { operation, text } (only for gg's own tests;
-- resources always use files).
local function resolve_query(q)
  if type(q) == "table" and type(q.operation) == "string" and type(q.text) == "string" then
    return q.text, q.operation, nil
  end
  local text, err = M.load(q)
  if not text then
    return nil, nil, err
  end
  return text, M.operation_name(q), nil
end

--- Run a query or mutation. Resolves with the `data` object.
---@param host string
---@param name gg.GraphqlQueryRef query file name (without .graphql)
---@param variables? table
---@return gg.Task
function M.query(host, name, variables)
  local text, op, lerr = resolve_query(name)
  if not text then
    return task.failed(lerr)
  end
  local settings, herr = config.host(host)
  if not settings then
    return task.failed(herr)
  end
  local body = vim.json.encode({ query = text, variables = variables or vim.empty_dict(), operationName = op })
  return task.run(function()
    local res, err = http.request({
      host = host,
      method = "POST",
      url = settings.base_url .. M.ENDPOINT,
      headers = { ["Content-Type"] = "application/json", Accept = "application/json" },
      body = body,
      decode = "json",
    }):await()
    if err then
      if err.details then
        err.details.operation = op
      end
      return nil, err
    end
    local payload = res.data
    if type(payload) ~= "table" then
      return nil, errors.new("unknown", "empty GraphQL response", { details = { operation = op } })
    end
    if type(payload.errors) == "table" and #payload.errors > 0 then
      return nil, errors.new("graphql", summarize(payload.errors), {
        status = res.status,
        details = { operation = op, errors = normalize_errors(payload.errors), partial = payload.data },
      })
    end
    if payload.data == nil then
      return nil, errors.new("graphql", "GraphQL response has no data", { details = { operation = op } })
    end
    return payload.data
  end)
end

--- Walk a dotted path ("project.issue") into data.
---@param data any
---@param path string
---@return any
function M.get(data, path)
  local v = data
  for key in path:gmatch("[^%.]+") do
    if type(v) ~= "table" then
      return nil
    end
    v = v[key]
  end
  return v
end

--- The value at `path`, or a `not_found` error when any part is null.
--- (GraphQL returns null, without an error, for objects the user can't see.)
---@param data any
---@param path string
---@param what? string what was looked up, for the message
---@return any value
---@return gg.Error|nil
function M.require(data, path, what)
  local v = M.get(data, path)
  if v == nil then
    return nil, errors.new("not_found", (what or path) .. " not found (or not visible to this token)", {
      details = { path = path },
    })
  end
  return v, nil
end

--- A `validation` error for a mutation payload's `errors`, or nil.
---@param payload table|nil
---@param operation string
---@return gg.Error|nil
function M.payload_error(payload, operation)
  if type(payload) == "table" and type(payload.errors) == "table" and #payload.errors > 0 then
    local msgs = {}
    for _, m in ipairs(payload.errors) do
      table.insert(msgs, tostring(m))
    end
    return errors.new("validation", table.concat(msgs, "; "), { details = { operation = operation, errors = msgs } })
  end
  return nil
end

local SCHEMA_PATTERNS = {
  "doesn't exist on type",
  "doesn't accept argument",
  "isn't a defined input type",
  "is not defined on",
  "Unknown type",
  "No such type",
}

local SCHEMA_CODES = {
  undefinedField = true,
  argumentNotAccepted = true,
  undefinedType = true,
  missingRequiredArguments = false,
}

--- True when a GraphQL error says the schema lacks a field, argument or type
--- (an older GitLab). Used for version-skew fallbacks; auth and network
--- errors are never schema errors.
---@param err any
---@return boolean
function M.is_schema_error(err)
  if not errors.is(err) or err.kind ~= "graphql" or type(err.details) ~= "table" then
    return false
  end
  for _, e in ipairs(err.details.errors or {}) do
    local code = type(e.extensions) == "table" and e.extensions.code
    if code and SCHEMA_CODES[code] then
      return true
    end
    local msg = tostring(e.message or "")
    for _, p in ipairs(SCHEMA_PATTERNS) do
      if msg:find(p, 1, true) then
        return true
      end
    end
  end
  return false
end

---@class gg.GraphqlPageOptions
---@field per_page? integer
---@field default_per_page? integer
---@field cursor? string
---@field what? string for not_found messages

--- One page of a connection. `variables` gets `first` and `after`; the
--- connection at `connection_path` must select `nodes` and
--- `pageInfo { hasNextPage endCursor }`. Resolves with `gg.Page` of raw nodes
--- plus `data` (the whole response data, for fields outside the connection).
---@param host string
---@param name gg.GraphqlQueryRef query file name
---@param variables table
---@param connection_path string e.g. "project.issues"
---@param opts? gg.GraphqlPageOptions
---@return gg.Task
function M.page(host, name, variables, connection_path, opts)
  opts = opts or {}
  local after, aerr = pagination.graphql_after(opts.cursor)
  if aerr then
    return task.failed(aerr)
  end
  local vars = vim.deepcopy(variables or {})
  vars.first = pagination.per_page(opts.per_page, opts.default_per_page)
  vars.after = after
  return task.run(function()
    local data, err = M.query(host, name, vars):await()
    if err then
      return nil, err
    end
    local parent = connection_path:match("^(.*)%.[^%.]+$")
    if parent then
      local _, perr = M.require(data, parent, opts.what)
      if perr then
        return nil, perr
      end
    end
    local conn = M.get(data, connection_path)
    if type(conn) ~= "table" then
      return nil, errors.new("unknown", "GraphQL response has no connection at " .. connection_path)
    end
    return { items = conn.nodes or {}, next_cursor = pagination.graphql_next(conn.pageInfo), data = data }
  end)
end

--- Collect a connection across pages, up to `opts.limit`.
---@param host string
---@param name gg.GraphqlQueryRef
---@param variables table
---@param connection_path string
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: any[]), what?: string }
---@return gg.Task resolves with gg.Collected of raw nodes
function M.paginate(host, name, variables, connection_path, opts)
  opts = opts or {}
  return pagination.collect(function(_, o)
    return M.page(host, name, variables, connection_path, { cursor = o.cursor, per_page = o.per_page, what = opts.what })
  end, {}, opts)
end

--- GraphQL global ID for a numeric project ID.
---@param id integer|string
---@return string
local function project_gid(id)
  return "gid://gitlab/Project/" .. tostring(id)
end

--- The full path of a project given as a path or a numeric ID. A path
--- resolves at once; an ID costs one lookup (there is no cache).
---@param host string
---@param project any
---@return gg.Task resolves with string
function M.project_path(host, project)
  if type(project) == "string" and not project:match("^%d+$") then
    local path = project:gsub("^/+", ""):gsub("/+$", "")
    if path:find("/", 1, true) and not path:find("//", 1, true) and not path:match("%s") then
      return task.resolved(path)
    end
  end
  local id = tonumber(project)
  if not id or id < 1 or math.floor(id) ~= id then
    return task.failed(errors.new("validation", "project must be a numeric ID or a full path like group/project", {
      details = { key = "project" },
    }))
  end
  return task.run(function()
    local data, err = M.query(host, "project_path", { ids = { project_gid(id) } }):await()
    if err then
      return nil, err
    end
    local node = (M.get(data, "projects.nodes") or {})[1]
    if not node or type(node.fullPath) ~= "string" then
      return nil, errors.new("not_found", ("project %d not found (or not visible to this token)"):format(id), {
        details = { project = id },
      })
    end
    return node.fullPath
  end)
end

return M
