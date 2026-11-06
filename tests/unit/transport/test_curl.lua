local H = require("tests.helpers")
local server = require("tests.support.server")
local curl = require("gg.transport.backends.curl")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local TOKEN = "glpat-loopbacktesttoken"

local function base_req(over)
  return vim.tbl_extend("force", {
    method = "GET",
    url = "https://gitlab.example.com/api/v4/projects",
    headers = { ["PRIVATE-TOKEN"] = TOKEN, Accept = "application/json" },
    timeout = { connect = 10, total = 60, stall = 30 },
  }, over or {})
end

-- send through curl and wait for the result (tests only)
local function send(req, ms)
  local done, res, err = false, nil, nil
  local cancel = curl.send(req, function(r, e)
    done, res, err = true, r, e
  end)
  H.wait_for(function()
    return done
  end, ms or 10000)
  return res, err, cancel
end

T["build: the token is only in stdin, never in argv"] = function()
  local b = curl.build(base_req())
  eq(table.concat(b.argv, " "):find(TOKEN, 1, true), nil)
  eq(table.concat(b.argv, " "):find("gitlab.example.com", 1, true), nil)
  eq(b.stdin:find('header = "PRIVATE-TOKEN: ' .. TOKEN .. '"', 1, true) ~= nil, true)
  eq(b.stdin:find('url = "https://gitlab.example.com/api/v4/projects"', 1, true) ~= nil, true)
  eq(vim.tbl_contains(b.argv, "--config"), true)
  eq(vim.tbl_contains(b.argv, "--globoff"), true)
end

T["build: GET has no request line, POST does"] = function()
  eq(curl.build(base_req()).stdin:find("request =", 1, true), nil)
  eq(curl.build(base_req({ method = "POST", body = "{}" })).stdin:find('request = "POST"', 1, true) ~= nil, true)
end

T["build: quoting of quotes, backslashes and newlines"] = function()
  eq(curl.quote('a"b\\c\nd\te'), '"a\\"b\\\\c\\nd\\te"')
  local b = curl.build(base_req({ method = "POST", body = '{"path":"C:\\\\x","t":"a\nb"}' }))
  eq(b.stdin:find('data-raw = "{\\"path\\":\\"C:\\\\\\\\x\\",\\"t\\":\\"a\\nb\\"}"', 1, true) ~= nil, true)
end

T["build: timeouts, and stall instead of total for streams"] = function()
  local b = curl.build(base_req())
  eq(b.stdin:find('connect-timeout = "10"', 1, true) ~= nil, true)
  eq(b.stdin:find('max-time = "60"', 1, true) ~= nil, true)
  eq(b.stdin:find("speed-time", 1, true), nil)
  local s = curl.build(base_req({ output = "/tmp/out.zip", timeout = { connect = 5, total = 0, stall = 30 } }))
  eq(s.stdin:find("max-time", 1, true), nil)
  eq(s.stdin:find('speed-time = "30"', 1, true) ~= nil, true)
  eq(s.part, "/tmp/out.zip.part")
  eq(vim.tbl_contains(s.argv, "/tmp/out.zip.part"), true)
end

T["headers: blocks, 1xx skipped, repeated headers joined"] = function()
  local dump = "HTTP/1.1 100 Continue\r\n\r\nHTTP/2 200\r\nContent-Type: application/json\r\nLink: <a>; rel=\"next\"\r\nlink: <b>; rel=\"last\"\r\n\r\n{\"a\":1}"
  local split = curl.split_headers(dump)
  eq(split.status, 200)
  eq(split.headers["content-type"], "application/json")
  eq(split.headers["link"], '<a>; rel="next", <b>; rel="last"')
  eq(split.rest, '{"a":1}')
  eq(curl.split_headers("HTTP/1.1 200 OK\r\nX-A: 1\r\n"), nil)
  local lf = curl.split_headers("HTTP/1.1 404 Not Found\nX-B: 2\n\nbody")
  eq({ lf.status, lf.headers["x-b"], lf.rest }, { 404, "2", "body" })
end

T["exit codes"] = function()
  eq(curl.exit_error(28, "Operation timed out").kind, "timeout")
  eq(curl.exit_error(7, "Failed to connect").kind, "network")
  eq(curl.exit_error(6, "Could not resolve host").kind, "network")
  eq(curl.exit_error(35, "SSL connect error").kind, "network")
  eq(curl.exit_error(23, "write error").kind, "unknown")
  local e = curl.exit_error(7, "failed with token secret-abc-123", { "secret-abc-123" })
  eq(e.message:find("secret-abc-123", 1, true), nil)
  eq(e.details.curl_exit, 7)
  eq(curl.exit_error(52, "").message, "curl exited with code 52")
end

local srv
local loop = MiniTest.new_set({
  hooks = {
    pre_case = function()
      srv = server.start(function(req)
        if req.path == "/json" then
          return { status = 200, headers = { ["Content-Type"] = "application/json", ["X-Next-Page"] = "2" }, body = '{"ok":true}' }
        elseif req.path == "/echo" then
          return { status = 200, body = vim.json.encode({ method = req.method, headers = req.headers, body = req.body }) }
        elseif req.path == "/big" then
          return { status = 200, body = string.rep("0123456789", 20000) }
        elseif req.path == "/missing" then
          return { status = 404, body = '{"message":"404 Not Found"}' }
        elseif req.path == "/hang" then
          return { hang = true }
        end
        return { status = 500, body = "unexpected" }
      end)
    end,
    post_case = function()
      srv.close()
    end,
  },
})
T["loopback"] = loop

loop["GET with headers and JSON body"] = function()
  local res, err = send(base_req({ url = srv.url .. "/json" }))
  eq(err, nil)
  eq(res.status, 200)
  eq(res.headers["x-next-page"], "2")
  eq(res.body, '{"ok":true}')
end

loop["headers, token and body arrive intact"] = function()
  local body = '{"q":"say \\"hi\\"","p":"C:\\\\dir","nl":"a\\nb","u":"ünï"}'
  local res = send(base_req({ method = "POST", url = srv.url .. "/echo", body = body, headers = {
    ["PRIVATE-TOKEN"] = TOKEN,
    ["Content-Type"] = "application/json",
  } }))
  local echo = vim.json.decode(res.body)
  eq(echo.method, "POST")
  eq(echo.headers["private-token"], TOKEN)
  eq(echo.headers["content-type"], "application/json")
  eq(echo.body, body)
end

loop["streaming to a file"] = function()
  local out = vim.fn.tempname() .. ".bin"
  local res, err = send(base_req({ url = srv.url .. "/big", output = out }))
  eq(err, nil)
  eq(res.status, 200)
  eq(res.body, nil)
  eq(res.bytes, 200000)
  eq(H.read(out), string.rep("0123456789", 20000))
  eq(vim.uv.fs_stat(out .. ".part"), nil)
  os.remove(out)
end

loop["streaming to a callback"] = function()
  local chunks = {}
  local res = send(base_req({ url = srv.url .. "/big", on_chunk = function(d)
    table.insert(chunks, d)
  end }))
  H.flush()
  eq(res.bytes, 200000)
  eq(table.concat(chunks), string.rep("0123456789", 20000))
end

loop["error bodies are never streamed"] = function()
  local chunks = {}
  local res = send(base_req({ url = srv.url .. "/missing", on_chunk = function(d)
    table.insert(chunks, d)
  end }))
  H.flush()
  eq(chunks, {})
  eq(res.status, 404)
  eq(res.body, '{"message":"404 Not Found"}')

  local out = vim.fn.tempname() .. ".bin"
  local res2 = send(base_req({ url = srv.url .. "/missing", output = out }))
  eq(res2.status, 404)
  eq(res2.body, '{"message":"404 Not Found"}')
  eq(vim.uv.fs_stat(out), nil)
  H.wait_for(function()
    return vim.uv.fs_stat(out .. ".part") == nil
  end)
end

loop["cancel stops the request and never calls back"] = function()
  local out = vim.fn.tempname() .. ".bin"
  local called = false
  local cancel = curl.send(base_req({ url = srv.url .. "/hang", output = out }), function()
    called = true
  end)
  H.wait_for(function()
    return #srv.requests == 1
  end, 10000)
  cancel()
  H.flush(300)
  eq(called, false)
  H.wait_for(function()
    return vim.uv.fs_stat(out .. ".part") == nil
  end)
end

loop["connection refused is a network error"] = function()
  local _, err = send(base_req({ url = "http://127.0.0.1:" .. server.closed_port() .. "/x" }))
  eq(err.kind, "network")
end

loop["timeout is a timeout error"] = function()
  local _, err = send(base_req({ url = srv.url .. "/hang", timeout = { connect = 5, total = 1, stall = 0 } }))
  eq(err.kind, "timeout")
end

return T
