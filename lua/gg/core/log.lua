--- Leveled logging with a pluggable sink. Every message and field is redacted.
---
--- The level and sink are configured defaults (set through `gg.setup`), not
--- per-request state. The default sink appends to `stdpath("log")/gg.log`
--- with async `vim.uv` file I/O.
local redact = require("gg.core.redact")
local errors = require("gg.core.errors")

local M = {}

---@alias gg.LogLevel "trace"|"debug"|"info"|"warn"|"error"|"off"

---@alias gg.LogSink fun(level: gg.LogLevel, message: string, fields: table|nil)

M.LEVELS = { trace = 0, debug = 1, info = 2, warn = 3, error = 4, off = 5 }

local function default_file()
  return vim.fs.joinpath(vim.fn.stdpath("log"), "gg.log")
end

local function format_fields(fields)
  if fields == nil or next(fields) == nil then
    return ""
  end
  local keys = vim.tbl_keys(fields)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = fields[k]
    if type(v) == "table" then
      v = vim.inspect(v, { newline = " ", indent = "" })
    end
    table.insert(parts, ("%s=%s"):format(tostring(k), tostring(v)))
  end
  return " " .. table.concat(parts, " ")
end

--- Format one log line (used by the file sink).
---@param level gg.LogLevel
---@param message string
---@param fields table|nil
---@return string
function M.format(level, message, fields)
  return ("%s [%s] %s%s\n"):format(os.date("!%Y-%m-%dT%H:%M:%SZ"), level:upper(), message, format_fields(fields))
end

--- A sink that appends formatted lines to `path` with async file I/O.
---@param path string
---@return gg.LogSink
function M.file_sink(path)
  return function(level, message, fields)
    local line = M.format(level, message, fields)
    local dir = vim.fs.dirname(path)
    if dir and vim.fn.isdirectory(dir) == 0 then
      pcall(vim.fn.mkdir, dir, "p")
    end
    vim.uv.fs_open(path, "a", 420, function(open_err, fd)
      if open_err or not fd then
        return
      end
      vim.uv.fs_write(fd, line, -1, function()
        vim.uv.fs_close(fd, function() end)
      end)
    end)
  end
end

-- configured defaults
local state = {
  level = M.LEVELS.warn,
  level_name = "warn",
  sink = nil, ---@type gg.LogSink|nil (nil = file sink at the default path)
  file = nil, ---@type string|nil
}

local function current_sink()
  if state.sink then
    return state.sink
  end
  return M.file_sink(state.file or default_file())
end

--- Configure the log. `level` defaults to "warn"; `sink` replaces the file
--- sink; `file` changes the file the default sink writes to.
---@param opts? { level?: gg.LogLevel, sink?: gg.LogSink, file?: string }
---@return boolean ok
---@return gg.Error|nil err
function M.configure(opts)
  opts = opts or {}
  if opts.level ~= nil and M.LEVELS[opts.level] == nil then
    return false, errors.new("validation", "log.level must be one of trace, debug, info, warn, error, off", {
      details = { key = "log.level", value = tostring(opts.level) },
    })
  end
  if opts.sink ~= nil and type(opts.sink) ~= "function" then
    return false, errors.new("validation", "log.sink must be a function", { details = { key = "log.sink" } })
  end
  if opts.file ~= nil and type(opts.file) ~= "string" then
    return false, errors.new("validation", "log.file must be a string", { details = { key = "log.file" } })
  end
  state.level_name = opts.level or "warn"
  state.level = M.LEVELS[state.level_name]
  state.sink = opts.sink
  state.file = opts.file
  return true, nil
end

--- The configured level name.
---@return gg.LogLevel
function M.level()
  return state.level_name
end

--- True when messages at `level` are written.
---@param level gg.LogLevel
---@return boolean
function M.enabled(level)
  local n = M.LEVELS[level]
  return n ~= nil and n < M.LEVELS.off and n >= state.level
end

--- Write a message. `fields` may be a table or a function returning one (only
--- called when the level is enabled). Never throws.
---@param level gg.LogLevel
---@param message string
---@param fields? table|fun(): table
function M.log(level, message, fields)
  if not M.enabled(level) then
    return
  end
  local ok_fields, f = true, fields
  if type(fields) == "function" then
    ok_fields, f = pcall(fields)
    if not ok_fields then
      f = { fields_error = tostring(f) }
    end
  end
  local msg = redact.string(tostring(message))
  local safe = f ~= nil and redact.value(f) or nil
  pcall(current_sink(), level, msg, safe)
end

---@param message string
---@param fields? table|fun(): table
function M.trace(message, fields)
  M.log("trace", message, fields)
end

---@param message string
---@param fields? table|fun(): table
function M.debug(message, fields)
  M.log("debug", message, fields)
end

---@param message string
---@param fields? table|fun(): table
function M.info(message, fields)
  M.log("info", message, fields)
end

---@param message string
---@param fields? table|fun(): table
function M.warn(message, fields)
  M.log("warn", message, fields)
end

---@param message string
---@param fields? table|fun(): table
function M.error(message, fields)
  M.log("error", message, fields)
end

return M
