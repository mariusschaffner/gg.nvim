--- Normalized errors. Every failure that crosses the public API is a `gg.Error`.
---
--- Kinds (CLAUDE.md): auth, forbidden, not_found, validation, rate_limited,
--- timeout, network, graphql, unknown.
local redact = require("gg.core.redact")

local M = {}

---@alias gg.ErrorKind "auth"|"forbidden"|"not_found"|"validation"|"rate_limited"|"timeout"|"network"|"graphql"|"unknown"

---@class gg.Error
---@field kind gg.ErrorKind
---@field status integer|nil HTTP status, when there was a response
---@field message string human readable, already redacted
---@field details table|nil extra context, already redacted

---@type gg.ErrorKind[]
M.KINDS = { "auth", "forbidden", "not_found", "validation", "rate_limited", "timeout", "network", "graphql", "unknown" }

local KIND_SET = {}
for _, k in ipairs(M.KINDS) do
  KIND_SET[k] = true
end

local ErrorMT = {}
ErrorMT.__index = ErrorMT
ErrorMT.__tostring = function(self)
  if self.status then
    return ("gg: %s (%d): %s"):format(self.kind, self.status, self.message)
  end
  return ("gg: %s: %s"):format(self.kind, self.message)
end

--- Create an error. An unknown `kind` becomes "unknown" with `details.invalid_kind`.
--- The message and details are redacted (token patterns, secret keys, and any
--- exact value in `opts.secrets`).
---@param kind gg.ErrorKind
---@param message string
---@param opts? { status?: integer, details?: table, secrets?: string[] }
---@return gg.Error
function M.new(kind, message, opts)
  opts = opts or {}
  local details = opts.details
  if not KIND_SET[kind] then
    details = vim.tbl_extend("force", details or {}, { invalid_kind = tostring(kind) })
    kind = "unknown"
  end
  local err = {
    kind = kind,
    status = type(opts.status) == "number" and opts.status or nil,
    message = redact.string(tostring(message or kind), opts.secrets),
    details = details ~= nil and redact.value(details, opts.secrets) or nil,
  }
  return setmetatable(err, ErrorMT)
end

--- Copy of `err` with extra secrets redacted (used when a request knows the
--- exact token it sent).
---@param err gg.Error
---@param secrets string[]
---@return gg.Error
function M.redact(err, secrets)
  return M.new(err.kind, err.message, { status = err.status, details = err.details, secrets = secrets })
end

--- True when `v` looks like a gg error (kind + message), including plain
--- tables of the same shape returned by the pure modules.
---@param v any
---@return boolean
function M.is(v)
  return type(v) == "table" and type(v.kind) == "string" and KIND_SET[v.kind] == true and type(v.message) == "string"
end

--- The error a cancelled task reports to a coroutine that is still waiting on it.
---@return gg.Error
function M.cancelled()
  return M.new("unknown", "cancelled", { details = { cancelled = true } })
end

--- True when `err` reports a cancellation.
---@param err any
---@return boolean
function M.is_cancelled(err)
  return M.is(err) and type(err.details) == "table" and err.details.cancelled == true
end

--- Turn anything into a gg.Error. gg errors pass through unchanged.
---@param v any
---@return gg.Error
function M.wrap(v)
  if getmetatable(v) == ErrorMT then
    return v
  end
  if M.is(v) then
    return M.new(v.kind, v.message, { status = v.status, details = v.details })
  end
  if type(v) == "string" then
    return M.new("unknown", v)
  end
  return M.new("unknown", vim.inspect(v))
end

return M
