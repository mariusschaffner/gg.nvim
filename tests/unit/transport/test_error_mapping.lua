local H = require("tests.helpers")
local curl = require("gg.transport.backends.curl")
local http = require("gg.transport.http")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local URL = "https://gitlab.example.com/api/v4/projects/g%2Fr/issues/1?private_token=leak"

local function respond(response, opts)
  local fake = H.fake()
  fake:add({ request = { path = "/api/v4/projects/g%2Fr/issues/1" }, response = response })
  return H.await(http.request(vim.tbl_extend("force", { host = H.TEST_HOST, url = URL }, opts or {})))
end

local statuses = {
  { 400, "validation", { message = { title = { "can't be blank", "is too short" }, labels = { "is invalid" } } }, "400 Bad Request: labels is invalid; title can't be blank, is too short" },
  { 401, "auth", { message = "401 Unauthorized" }, nil },
  { 403, "forbidden", { message = "403 Forbidden" }, "403 Forbidden" },
  { 404, "not_found", { message = "404 Project Not Found" }, "404 Project Not Found" },
  { 405, "validation", { message = "405 Method Not Allowed" }, "405 Method Not Allowed" },
  { 409, "validation", { message = "Branch already exists" }, "409 Conflict: Branch already exists" },
  { 422, "validation", { message = { "Source branch is missing" } }, "422 Unprocessable Entity: Source branch is missing" },
  { 429, "rate_limited", "Retry later", "429 Too Many Requests: Retry later" },
  { 500, "unknown", { message = "500 Internal Server Error" }, "500 Internal Server Error" },
  { 502, "unknown", "<html>bad gateway</html>", "502 Bad Gateway" },
  { 503, "unknown", nil, "503 Service Unavailable" },
  { 400, "validation", { error = "invalid_grant", error_description = "expired" }, "400 Bad Request: invalid_grant: expired" },
}

for _, c in ipairs(statuses) do
  T[("status %d -> %s"):format(c[1], c[2])] = function()
    local _, err = respond({ status = c[1], body = c[3], headers = { ["X-Request-Id"] = "req-123", ["Retry-After"] = "7" } })
    eq(err.kind, c[2])
    eq(err.status, c[1])
    if c[4] then
      eq(err.message, c[4])
    end
    eq(err.details.method, "GET")
    eq(err.details.request_id, "req-123")
    eq(err.details.url, "https://gitlab.example.com/api/v4/projects/g%2Fr/issues/1")
    if c[1] == 429 then
      eq(err.details.retry_after, 7)
    end
  end
end

T["error bodies are truncated and redacted"] = function()
  local body = { message = "boom", token = H.TEST_TOKEN, filler = string.rep("x", 5000) }
  local _, err = respond({ status = 500, body = body })
  -- truncated to the limit before redaction, so redaction can only shorten it
  eq(#err.details.body <= http.ERROR_BODY_LIMIT, true)
  eq(#err.details.body > http.ERROR_BODY_LIMIT - 100, true)
  eq(err.details.body:find(H.TEST_TOKEN, 1, true), nil)
end

T["a 2xx body with a message field is not an error"] = function()
  local res, err = respond({ status = 200, body = { message = "this is a commit message", id = 1 } }, { decode = "json" })
  eq(err, nil)
  eq(res.data.message, "this is a commit message")
end

T["204 and empty 2xx decode to nil"] = function()
  local res, err = respond({ status = 204 }, { decode = "json" })
  eq(err, nil)
  eq(res.status, 204)
  eq(res.data, nil)
end

T["JSON null becomes nil"] = function()
  local res = respond({ status = 200, body = '{"a":null,"b":[1,null]}' }, { decode = "json" })
  eq(res.data.a, nil)
  eq(res.data.b[1], 1)
end

T["invalid JSON is unknown"] = function()
  local _, err = respond({ status = 200, body = "{not json" }, { decode = "json" })
  eq(err.kind, "unknown")
  eq(err.message, "invalid JSON in response")
end

T["304 is not an error"] = function()
  local res, err = respond({ status = 304 })
  eq(err, nil)
  eq(res.status, 304)
end

local exits = { { 6, "network" }, { 7, "network" }, { 28, "timeout" }, { 35, "network" }, { 23, "unknown" } }
for _, c in ipairs(exits) do
  T[("curl exit %d -> %s"):format(c[1], c[2])] = function()
    eq(curl.exit_error(c[1], "x").kind, c[2])
  end
end

T["fake transport errors keep their kind"] = function()
  for _, kind in ipairs({ "timeout", "network" }) do
    local _, err = respond({ error = { kind = kind } })
    eq(err.kind, kind)
  end
end

T["body_message"] = function()
  eq(http.body_message({ message = "x" }), "x")
  eq(http.body_message({ errors = { { message = "a" }, "b" } }), "a; b")
  eq(http.body_message(nil, "plain text error\n"), "plain text error ")
  eq(http.body_message(nil, "<html></html>"), nil)
  eq(http.body_message({}, nil), nil)
end

return T
