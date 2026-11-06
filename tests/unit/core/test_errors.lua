local errors = require("gg.core.errors")
local redact = require("gg.core.redact")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["new: fields"] = function()
  local err = errors.new("not_found", "Issue not found", { status = 404, details = { iid = 3 } })
  eq(err.kind, "not_found")
  eq(err.status, 404)
  eq(err.message, "Issue not found")
  eq(err.details, { iid = 3 })
end

T["new: every CLAUDE.md kind is accepted"] = function()
  local expected = { "auth", "forbidden", "not_found", "validation", "rate_limited", "timeout", "network", "graphql", "unknown" }
  eq(errors.KINDS, expected)
  for _, k in ipairs(expected) do
    eq(errors.new(k, "x").kind, k)
  end
end

T["new: an invalid kind becomes unknown"] = function()
  local err = errors.new("conflict", "x")
  eq(err.kind, "unknown")
  eq(err.details.invalid_kind, "conflict")
end

T["new: a non-numeric status is dropped"] = function()
  eq(errors.new("unknown", "x", { status = "500" }).status, nil)
end

T["tostring"] = function()
  eq(tostring(errors.new("forbidden", "no access", { status = 403 })), "gg: forbidden (403): no access")
  eq(tostring(errors.new("network", "refused")), "gg: network: refused")
end

T["message and details are redacted"] = function()
  local err = errors.new("auth", "PRIVATE-TOKEN: glpat-xyz is wrong", {
    details = { headers = { ["PRIVATE-TOKEN"] = "glpat-xyz" }, body = "token glpat-xyz echoed" },
  })
  eq(err.message:find("glpat", 1, true), nil)
  eq(err.details.headers["PRIVATE-TOKEN"], redact.MASK)
  eq(err.details.body:find("glpat", 1, true), nil)
end

T["exact secrets are redacted"] = function()
  local err = errors.new("unknown", "server said: plain-old-token", { secrets = { "plain-old-token" }, details = { b = "plain-old-token" } })
  eq(err.message, "server said: " .. redact.MASK)
  eq(err.details.b, redact.MASK)
  local again = errors.redact(errors.new("unknown", "v=abc123456"), { "abc123456" })
  eq(again.message, "v=" .. redact.MASK)
end

T["is"] = function()
  eq(errors.is(errors.new("unknown", "x")), true)
  eq(errors.is({ kind = "validation", message = "plain table" }), true)
  eq(errors.is({ kind = "nope", message = "x" }), false)
  eq(errors.is("string"), false)
  eq(errors.is(nil), false)
end

T["cancelled"] = function()
  local err = errors.cancelled()
  eq(errors.is_cancelled(err), true)
  eq(err.kind, "unknown")
  eq(errors.is_cancelled(errors.new("unknown", "x")), false)
  eq(errors.is_cancelled(nil), false)
end

T["wrap"] = function()
  local e = errors.new("timeout", "slow")
  eq(errors.wrap(e) == e, true)
  local plain = errors.wrap({ kind = "validation", message = "bad", details = { token = "t" } })
  eq(plain.kind, "validation")
  eq(plain.details.token, redact.MASK)
  eq(tostring(plain), "gg: validation: bad")
  eq(errors.wrap("oops").kind, "unknown")
  eq(errors.wrap(42).message, "42")
end

return T
