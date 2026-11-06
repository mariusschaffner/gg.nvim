local H = require("tests.helpers")
local fake_backend = require("gg.transport.backends.fake")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

-- send through a fake and wait (tests only)
local function send(fake, req, ms)
  local done, res, err = false, nil, nil
  local cancel = fake.send(vim.tbl_extend("force", { method = "GET", headers = {} }, req), function(r, e)
    done, res, err = true, r, e
  end)
  H.wait_for(function()
    return done
  end, ms or 2000)
  return res, err, cancel
end

local BASE = "https://gitlab.example.com"

T["parse_url"] = function()
  local path, query = fake_backend.parse_url(BASE .. "/api/v4/projects/a%2Fb/issues?state=opened&labels=a%2Cb&iids[]=1&iids[]=2&x=1&x=2#frag")
  eq(path, "/api/v4/projects/a%2Fb/issues")
  eq(query, { state = "opened", labels = "a,b", iids = { "1", "2" }, x = { "1", "2" } })
end

T["REST: matches method, raw path and exact query, in any order"] = function()
  local fake = fake_backend.new():load(H.path("tests/fixtures/transport/fake_basic.json"))
  local res = send(fake, { url = BASE .. "/api/v4/projects/group%2Frepo/labels?per_page=2&page=1" })
  eq(res.status, 200)
  eq(res.headers["x-next-page"], "2")
  eq(vim.json.decode(res.body)[2].name, "feature")
  local res2 = send(fake, { url = BASE .. "/api/v4/projects/group%2Frepo/labels?page=2&per_page=2" })
  eq(#vim.json.decode(res2.body), 1)
  eq(#fake:unused(), 0)
end

T["REST: exact query rejects extra parameters; query_contains allows them"] = function()
  local fake = fake_backend.new():add({
    request = { path = "/x", query = { a = "1" } },
    response = { body = { ok = 1 } },
  }):add({
    request = { path = "/y", query_contains = { a = "1" } },
    response = { body = { ok = 2 } },
  })
  local _, err = send(fake, { url = BASE .. "/x?a=1&b=2" })
  eq(err.kind, "unknown")
  local res = send(fake, { url = BASE .. "/y?a=1&b=2" })
  eq(vim.json.decode(res.body).ok, 2)
end

T["REST: method must match; body_contains matches JSON bodies"] = function()
  local fake = fake_backend.new():add({
    request = { method = "POST", path = "/x", body_contains = { title = "T" } },
    response = { status = 201, body = { id = 9 } },
  })
  local _, err = send(fake, { url = BASE .. "/x" })
  eq(err.kind, "unknown")
  local res = send(fake, { method = "POST", url = BASE .. "/x", body = vim.json.encode({ title = "T", other = 1 }) })
  eq(res.status, 201)
end

T["GraphQL: matches operation and a subset of variables"] = function()
  local fake = fake_backend.new():add({
    request = { operation = "IssueGet", variables = { fullPath = "g/r", iid = "3" } },
    response = { body = { data = { project = { issue = { iid = "3" } } } } },
  })
  local body = vim.json.encode({ query = "query IssueGet {}", operationName = "IssueGet", variables = { fullPath = "g/r", iid = "3", extra = true } })
  local res = send(fake, { method = "POST", url = BASE .. "/api/graphql", body = body })
  eq(vim.json.decode(res.body).data.project.issue.iid, "3")
  local rec = fake:last()
  eq(rec.operation, "IssueGet")
  eq(rec.variables.extra, true)
end

T["fixtures are used once, unless repeat"] = function()
  local fake = fake_backend.new()
    :add({ request = { path = "/r" }, response = { status = 429 } })
    :add({ request = { path = "/r" }, response = { status = 200 } })
    :add({ request = { path = "/s" }, response = { status = 204 }, ["repeat"] = true })
  eq(send(fake, { url = BASE .. "/r" }).status, 429)
  eq(send(fake, { url = BASE .. "/r" }).status, 200)
  local _, err = send(fake, { url = BASE .. "/r" })
  eq(err.kind, "unknown")
  eq(err.details.candidates, { "GET /r (used)", "GET /r (used)" })
  eq(send(fake, { url = BASE .. "/s" }).status, 204)
  eq(send(fake, { url = BASE .. "/s" }).status, 204)
end

T["unmatched requests list the closest fixtures"] = function()
  local fake = fake_backend.new():add({ request = { path = "/a", query = { page = "1" } }, response = {} })
  local _, err = send(fake, { url = BASE .. "/a?page=9" })
  eq(err.message:find("no fixture for GET /a?page=", 1, true) ~= nil, true)
  eq(#err.details.candidates, 1)
end

T["requests are recorded"] = function()
  local fake = fake_backend.new():add({ request = { path = "/a" }, response = {}, ["repeat"] = true })
  send(fake, { url = BASE .. "/a?x=1", headers = { Accept = "application/json" } })
  local rec = fake:requests()[1]
  eq(rec.method, "GET")
  eq(rec.path, "/a")
  eq(rec.query, { x = "1" })
  eq(rec.headers.Accept, "application/json")
  fake:reset()
  eq(#fake:requests(), 0)
end

T["injected failures and delays"] = function()
  local fake = fake_backend.new()
    :add({ request = { path = "/t" }, response = { error = { kind = "timeout" } } })
    :add({ request = { path = "/n" }, response = { error = { kind = "network", message = "refused" } } })
    :add({ request = { path = "/d" }, response = { status = 200, delay = 60 } })
  local _, e1 = send(fake, { url = BASE .. "/t" })
  eq(e1.kind, "timeout")
  local _, e2 = send(fake, { url = BASE .. "/n" })
  eq({ e2.kind, e2.message }, { "network", "refused" })
  local t0 = vim.uv.now()
  send(fake, { url = BASE .. "/d" })
  eq(vim.uv.now() - t0 >= 50, true)
end

T["cancel suppresses the callback"] = function()
  local fake = fake_backend.new():add({ request = { path = "/d" }, response = { delay = 30 } })
  local called = false
  local cancel = fake.send({ method = "GET", url = BASE .. "/d", headers = {} }, function()
    called = true
  end)
  cancel()
  H.flush(80)
  eq(called, false)
end

T["streaming: output files and chunks, only for 2xx"] = function()
  local data = string.rep("abc", 5000)
  local fake = fake_backend.new({ chunk_size = 1000 })
    :add({ request = { path = "/f" }, response = { body_base64 = vim.base64.encode(data) } })
    :add({ request = { path = "/c" }, response = { body = data } })
    :add({ request = { path = "/e" }, response = { status = 404, body = { message = "404 Not Found" } } })
  local out = vim.fn.tempname()
  local res = send(fake, { url = BASE .. "/f", output = out })
  eq(res.bytes, #data)
  eq(H.read(out), data)
  os.remove(out)

  local chunks = {}
  local res2 = send(fake, { url = BASE .. "/c", on_chunk = function(c)
    table.insert(chunks, c)
  end })
  eq(#chunks, 15)
  eq(table.concat(chunks), data)
  eq(res2.body, nil)

  local got = {}
  local res3 = send(fake, { url = BASE .. "/e", on_chunk = function(c)
    table.insert(got, c)
  end })
  eq(got, {})
  eq(res3.status, 404)
end

T["works as the configured backend"] = function()
  local fake = H.fake({ "transport/fake_basic.json" })
  local http = require("gg.transport.http")
  local res = H.await(http.send({ host = H.TEST_HOST, url = BASE .. "/api/v4/projects/group%2Frepo/labels?page=1&per_page=2" }))
  eq(res.status, 200)
  eq(#fake:requests(), 1)
  H.reset()
end

return T
