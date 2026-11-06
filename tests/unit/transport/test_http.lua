local H = require("tests.helpers")
local config = require("gg.config")
local http = require("gg.transport.http")
local eq = MiniTest.expect.equality

-- A stub backend that answers from a list and records the requests.
local calls, responses
local stub = {
  send = function(req, cb)
    table.insert(calls, vim.deepcopy(req))
    local res = responses[#calls] or { status = 200, headers = {}, body = "" }
    vim.schedule(function()
      cb(res, nil)
    end)
    return function() end
  end,
}

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      calls, responses = {}, {}
      config.setup({
        hosts = { ["gitlab.example.com"] = { base_url = "https://gitlab.example.com" } },
        transport = { backend = stub },
        log = { level = "off" },
      })
    end,
    post_case = function()
      config.setup({ log = { level = "off" } })
    end,
  },
})

local CRED = { ["PRIVATE-TOKEN"] = "secret-token-value" }

local function req(over)
  return vim.tbl_extend("force", {
    host = "gitlab.example.com",
    url = "https://gitlab.example.com/api/v4/x",
    credentials = CRED,
  }, over or {})
end

T["origin"] = function()
  eq(http.origin("https://GitLab.Example.com/a?b"), "https://gitlab.example.com")
  eq(http.origin("https://gitlab.example.com:443/a"), "https://gitlab.example.com")
  eq(http.origin("https://gitlab.example.com:8443/a"), "https://gitlab.example.com:8443")
  eq(http.origin("http://u:p@h.example.com:80"), "http://h.example.com")
  eq(http.origin("not a url"), nil)
end

T["resolve_location"] = function()
  local base = "https://gitlab.example.com/api/v4/jobs/1/artifacts?x=1"
  eq(http.resolve_location(base, "https://cdn.example.com/f"), "https://cdn.example.com/f")
  eq(http.resolve_location(base, "//cdn.example.com/f"), "https://cdn.example.com/f")
  eq(http.resolve_location(base, "/other"), "https://gitlab.example.com/other")
  eq(http.resolve_location(base, "file.zip"), "https://gitlab.example.com/api/v4/jobs/1/file.zip")
end

T["credentials are sent to the host's own origin"] = function()
  local res = H.await(http.send(req()))
  eq(res.status, 200)
  eq(calls[1].headers["PRIVATE-TOKEN"], "secret-token-value")
  eq(calls[1].method, "GET")
end

T["same-origin redirect keeps the credentials"] = function()
  responses = { { status = 302, headers = { location = "/api/v4/y" } } }
  local res = H.await(http.send(req()))
  eq(#calls, 2)
  eq(calls[2].url, "https://gitlab.example.com/api/v4/y")
  eq(calls[2].headers["PRIVATE-TOKEN"], "secret-token-value")
  eq(res.url, "https://gitlab.example.com/api/v4/y")
end

T["cross-origin redirect drops the credentials"] = function()
  responses = { { status = 302, headers = { location = "https://storage.example.net/blob?sig=1" } } }
  H.await(http.send(req({ headers = { Accept = "*/*" } })))
  eq(#calls, 2)
  eq(calls[2].url, "https://storage.example.net/blob?sig=1")
  eq(calls[2].headers["PRIVATE-TOKEN"], nil)
  eq(calls[2].headers.Accept, "*/*")
end

T["a different port is a different origin"] = function()
  responses = { { status = 301, headers = { location = "https://gitlab.example.com:8443/x" } } }
  H.await(http.send(req()))
  eq(calls[2].headers["PRIVATE-TOKEN"], nil)
end

T["303 turns into GET without a body; 307 keeps both"] = function()
  responses = { { status = 303, headers = { location = "/a" } } }
  H.await(http.send(req({ method = "POST", body = "{}" })))
  eq({ calls[2].method, calls[2].body }, { "GET", nil })
  calls = {}
  responses = { { status = 307, headers = { location = "/b" } } }
  H.await(http.send(req({ method = "POST", body = "{}" })))
  eq({ calls[2].method, calls[2].body }, { "POST", "{}" })
end

T["more than 5 redirects is a network error"] = function()
  for i = 1, 7 do
    responses[i] = { status = 302, headers = { location = "/r" .. i } }
  end
  local _, err = H.await(http.send(req()))
  eq(err.kind, "network")
  eq(#calls, 6)
end

T["a 3xx without Location is returned as is"] = function()
  responses = { { status = 304, headers = {} } }
  local res = H.await(http.send(req()))
  eq(res.status, 304)
end

T["streaming requests drop the total timeout"] = function()
  H.await(http.send(req({ output = "/tmp/x" })))
  eq(calls[1].timeout.total, 0)
  eq(calls[1].timeout.stall, 30)
  calls = {}
  H.await(http.send(req()))
  eq(calls[1].timeout.total, 60)
end

T["cancel cancels the backend request"] = function()
  local cancelled = 0
  config.setup({
    transport = {
      backend = {
        send = function()
          return function()
            cancelled = cancelled + 1
          end
        end,
      },
    },
    log = { level = "off" },
  })
  local t = http.send(req())
  t:cancel()
  eq(cancelled, 1)
end

T["validation"] = function()
  local cases = {
    "nope",
    { url = "https://h/x" },
    { host = "gitlab.example.com", url = "ftp://h/x" },
    { host = "gitlab.example.com", url = "https://h/x", headers = { ["X-A"] = "a\r\nInjected: 1" } },
    { host = "gitlab.example.com", url = "https://h/x", body = {} },
    { host = "gitlab.example.com", url = "https://h/x", output = "/tmp/a", on_chunk = function() end },
    { host = "https://gitlab.example.com", url = "https://h/x" },
  }
  for _, c in ipairs(cases) do
    local _, err = H.await(http.send(c))
    eq(err.kind, "validation")
  end
  eq(#calls, 0)
end

return T
