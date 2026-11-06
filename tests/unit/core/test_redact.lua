local redact = require("gg.core.redact")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local M = redact.MASK

local cases = {
  { "plain text stays", "issue not found", "issue not found" },
  { "personal access token", "bad token glpat-abcDEF123_-xyz here", "bad token " .. M .. " here" },
  { "oauth token", "gloas-0123456789abcdef", M },
  { "runner token", "glrt-t1_abcdefghijk", M },
  { "PRIVATE-TOKEN header", "PRIVATE-TOKEN: s3cr3t-value", "PRIVATE-TOKEN: " .. M },
  { "header case-insensitive", "private-token:abc", "private-token:" .. M },
  { "authorization header", "Authorization: Bearer abc.def", "Authorization: " .. M },
  { "JOB-TOKEN header", "JOB-TOKEN: 1234", "JOB-TOKEN: " .. M },
  { "private_token query", "https://h/api/v4/x?private_token=abc&a=1", "https://h/api/v4/x?private_token=" .. M .. "&a=1" },
  { "job_token query", "/download?job=build&job_token=xyz", "/download?job=build&job_token=" .. M },
  { "access_token query", "?access_token=zzz", "?access_token=" .. M },
  { "json token key", '{"token":"abc","a":1}', '{"token":"' .. M .. '","a":1}' },
  { "lua token key", 'token = "abc"', 'token = "' .. M .. '"' },
  { "password key", '{"password": "hunter2"}', '{"password": "' .. M .. '"}' },
  { "url userinfo", "https://oauth2:abc@gitlab.com/g/r.git", "https://" .. M .. "@gitlab.com/g/r.git" },
  { "ssh user is not a secret", "git@gitlab.com:g/r.git", "git@gitlab.com:g/r.git" },
}

for _, c in ipairs(cases) do
  T["string: " .. c[1]] = function()
    eq(redact.string(c[2]), c[3])
  end
end

T["string: exact secrets are masked, longest first"] = function()
  eq(redact.string("tok=abcd1234 and abcd", { "abcd", "abcd1234" }), "tok=" .. M .. " and " .. M)
end

T["string: secrets with pattern characters"] = function()
  eq(redact.string("x a.b%c+d y", { "a.b%c+d" }), "x " .. M .. " y")
end

T["string: very short secrets are ignored"] = function()
  eq(redact.string("a b c", { "a" }), "a b c")
end

T["value: deep copy with secret keys masked"] = function()
  local input = {
    url = "https://h/x?private_token=abc",
    headers = { ["PRIVATE-TOKEN"] = "abc", Accept = "application/json" },
    nested = { { token = "t", name = "ok" } },
    count = 3,
    flag = true,
  }
  local out = redact.value(input)
  eq(out.url, "https://h/x?private_token=" .. M)
  eq(out.headers["PRIVATE-TOKEN"], M)
  eq(out.headers.Accept, "application/json")
  eq(out.nested[1].token, M)
  eq(out.nested[1].name, "ok")
  eq(out.count, 3)
  eq(out.flag, true)
  -- the input is untouched
  eq(input.headers["PRIVATE-TOKEN"], "abc")
end

T["value: exact secrets anywhere"] = function()
  local out = redact.value({ body = "echo s3cret-token-value back", list = { "s3cret-token-value" } }, { "s3cret-token-value" })
  eq(out.body, "echo " .. M .. " back")
  eq(out.list[1], M)
end

T["value: cycles are safe"] = function()
  local a = { name = "a" }
  a.self = a
  local out = redact.value(a)
  eq(out.self, out)
end

T["is_secret_key"] = function()
  eq(redact.is_secret_key("Private-Token"), true)
  eq(redact.is_secret_key("access_token"), true)
  eq(redact.is_secret_key("title"), false)
  eq(redact.is_secret_key(1), false)
end

return T
