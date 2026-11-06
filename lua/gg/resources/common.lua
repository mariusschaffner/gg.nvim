--- Helpers shared by the resource modules: argument validation, the
--- list/list_all pair, and the instance origin for web paths.
---
--- Every public resource function validates its arguments and returns a
--- Task; nothing throws.
local config = require("gg.config")
local errors = require("gg.core.errors")
local http = require("gg.transport.http")
local pagination = require("gg.transport.pagination")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

--- A validation error naming the argument.
---@param key string
---@param message string
---@return gg.Error
function M.invalid(key, message)
  return errors.new("validation", ("args.%s %s"):format(key, message), { details = { key = key } })
end

local function is_pos_int(v)
  if type(v) == "string" and v:match("^%d+$") then
    v = tonumber(v)
  end
  return type(v) == "number" and v >= 1 and math.floor(v) == v
end

local function is_date(v)
  return type(v) == "string" and v:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

-- rule name -> { check(v) -> ok, description }
local RULES = {
  host = { config.is_host_name, "must be a bare host name like gitlab.example.com" },
  project = {
    function(v)
      return rest.project(v) ~= nil
    end,
    "must be a numeric ID or a full path like group/project",
  },
  group = {
    function(v)
      return type(v) == "string" and v:match("^[^%s/][^%s]*$") ~= nil and not v:find("//", 1, true)
    end,
    "must be a group full path like group or group/subgroup",
  },
  id = { is_pos_int, "must be a positive integer" },
  string = {
    function(v)
      return type(v) == "string" and v ~= ""
    end,
    "must be a non-empty string",
  },
  text = {
    function(v)
      return type(v) == "string"
    end,
    "must be a string",
  },
  boolean = {
    function(v)
      return type(v) == "boolean"
    end,
    "must be a boolean",
  },
  count = {
    function(v)
      return type(v) == "number" and v >= 0 and math.floor(v) == v
    end,
    "must be a non-negative integer",
  },
  date = { is_date, "must be a date like 2026-01-31" },
  date_or_false = {
    function(v)
      return v == false or is_date(v)
    end,
    "must be a date like 2026-01-31, or false to clear it",
  },
  id_or_false = {
    function(v)
      return v == false or is_pos_int(v)
    end,
    "must be a positive integer, or false to clear it",
  },
  strings = {
    function(v)
      if type(v) == "string" then
        return true
      end
      if type(v) ~= "table" or (next(v) ~= nil and not vim.islist(v)) then
        return false
      end
      for _, x in ipairs(v) do
        if type(x) ~= "string" or x == "" or x:find(",", 1, true) then
          return false
        end
      end
      return true
    end,
    "must be a list of strings (or a comma-separated string)",
  },
  ids = {
    function(v)
      if type(v) ~= "table" or (next(v) ~= nil and not vim.islist(v)) then
        return false
      end
      for _, x in ipairs(v) do
        if not is_pos_int(x) then
          return false
        end
      end
      return true
    end,
    "must be a list of positive integers",
  },
  callback = {
    function(v)
      return type(v) == "function"
    end,
    "must be a function",
  },
}

--- Validate `args` against a spec. Rules are names from RULES, with a "?"
--- suffix for optional keys, or `{ "one", "of", "these", optional = true }`
--- for enums. Unknown keys are rejected (they are usually typos).
---@param args any
---@param spec table<string, string|table>
---@return gg.Error|nil
function M.check(args, spec)
  if type(args) ~= "table" then
    return errors.new("validation", "arguments must be a table", { details = { key = "args" } })
  end
  for key in pairs(args) do
    if spec[key] == nil then
      return M.invalid(tostring(key), "is not a known argument")
    end
  end
  local keys = vim.tbl_keys(spec)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local rule = spec[key]
    local v = args[key]
    if type(rule) == "table" then
      if v == nil then
        if not rule.optional then
          return M.invalid(key, "is required")
        end
      elseif not vim.tbl_contains(rule, v) then
        return M.invalid(key, "must be one of: " .. table.concat(rule, ", "))
      end
    else
      local name, optional = rule:match("^([%w_]+)(%??)$")
      local r = RULES[name]
      if v == nil then
        if optional ~= "?" then
          return M.invalid(key, "is required")
        end
      elseif not r[1](v) then
        return M.invalid(key, r[2])
      end
    end
  end
  return nil
end

--- An enum rule for `check`.
---@param optional boolean
---@param ... string
---@return table
function M.enum(optional, ...)
  local t = { ... }
  t.optional = optional
  return t
end

--- Integer value of an ID given as a number or a digit string.
---@param v any
---@return integer|nil
function M.int(v)
  return tonumber(v)
end

--- A list or comma-separated string as a comma-separated string.
---@param v string|string[]|nil
---@return string|nil
function M.csv(v)
  if v == nil then
    return nil
  end
  if type(v) == "string" then
    return v
  end
  return table.concat(v, ",")
end

--- A list or comma-separated string as a list.
---@param v string|string[]|nil
---@return string[]|nil
function M.list(v)
  if v == nil then
    return nil
  end
  if type(v) == "table" then
    return v
  end
  local out = {}
  for part in v:gmatch("[^,]+") do
    local s = vim.trim(part)
    if s ~= "" then
      table.insert(out, s)
    end
  end
  return out
end

--- The origin of a host's base URL, for turning web paths into URLs.
---@param host string
---@return string|nil
function M.origin(host)
  local settings = config.host(host)
  return settings and http.origin(settings.base_url) or nil
end

--- Validate list options (`per_page`, `cursor`).
---@param opts any
---@return gg.Error|nil
function M.check_page_opts(opts)
  if opts == nil then
    return nil
  end
  if type(opts) ~= "table" then
    return errors.new("validation", "opts must be a table", { details = { key = "opts" } })
  end
  for k in pairs(opts) do
    if k ~= "per_page" and k ~= "cursor" then
      return errors.new("validation", ("opts.%s is not a known option"):format(tostring(k)), { details = { key = "opts." .. tostring(k) } })
    end
  end
  if opts.per_page ~= nil and not (type(opts.per_page) == "number" and opts.per_page >= 1 and opts.per_page <= 100 and math.floor(opts.per_page) == opts.per_page) then
    return errors.new("validation", "opts.per_page must be an integer from 1 to 100", { details = { key = "opts.per_page" } })
  end
  if opts.cursor ~= nil and type(opts.cursor) ~= "string" then
    return errors.new("validation", "opts.cursor must be a string from a previous page", { details = { key = "opts.cursor" } })
  end
  return nil
end

---@alias gg.FetchPage fun(args: table, opts: { cursor: string|nil, per_page: integer|nil }): gg.Task

--- Build the `list` (one page) and `list_all` (collect, required limit)
--- functions for a page fetcher.
---@param fetch_page gg.FetchPage
---@return fun(args: table, opts?: { per_page?: integer, cursor?: string }): gg.Task list
---@return fun(args: table, opts: { limit: integer, per_page?: integer, on_page?: fun(items: any[]) }): gg.Task list_all
function M.lists(fetch_page)
  local function list(args, opts)
    local oerr = M.check_page_opts(opts)
    if oerr then
      return task.failed(oerr)
    end
    opts = opts or {}
    return fetch_page(args, { cursor = opts.cursor, per_page = opts.per_page })
  end
  local function list_all(args, opts)
    if type(opts) ~= "table" then
      return task.failed(errors.new("validation", "opts.limit is required: a positive integer upper bound on the items to collect", {
        details = { key = "limit" },
      }))
    end
    for k in pairs(opts) do
      if k ~= "limit" and k ~= "per_page" and k ~= "on_page" then
        return task.failed(errors.new("validation", ("opts.%s is not a known option"):format(tostring(k)), { details = { key = "opts." .. tostring(k) } }))
      end
    end
    return pagination.collect(fetch_page, args, opts)
  end
  return list, list_all
end

--- Run `fn` as a task after validating `args` against `spec`.
---@param args any
---@param spec table
---@param fn fun(): any, gg.Error|nil
---@return gg.Task
function M.run(args, spec, fn)
  local err = M.check(args, spec)
  if err then
    return task.failed(err)
  end
  return task.run(fn)
end

return M
