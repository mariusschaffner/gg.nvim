local H = require("tests.helpers")
local auth = require("gg.transport.auth")
local config = require("gg.config")
local http = require("gg.transport.http")
local eq = MiniTest.expect.equality

local saved_env

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved_env = os.getenv("GITLAB_TOKEN")
      vim.env.GITLAB_TOKEN = nil
    end,
    post_case = function()
      vim.env.GITLAB_TOKEN = saved_env
      H.reset()
    end,
  },
})

local OK = { request = { path = "/api/v4/user" }, response = { status = 200, body = { id = 1 } }, ["repeat"] = true }

local function get(host)
  return http.request({ host = host or H.TEST_HOST, url = "https://" .. (host or H.TEST_HOST) .. "/api/v4/user" })
end

T["token from config"] = function()
  local fake = H.fake()
  fake:add(OK)
  H.await(get())
  eq(fake:last().headers["PRIVATE-TOKEN"], H.TEST_TOKEN)
end

T["token from a function, called per request"] = function()
  local n = 0
  local fake = H.fake(nil, { hosts = { [H.TEST_HOST] = { token = function()
    n = n + 1
    return "fn-token-" .. n
  end } } })
  fake:add(OK)
  H.await(get())
  H.await(get())
  eq(fake:requests()[1].headers["PRIVATE-TOKEN"], "fn-token-1")
  eq(fake:requests()[2].headers["PRIVATE-TOKEN"], "fn-token-2")
end

T["a failing token function is an auth error, and nothing is sent"] = function()
  local fake = H.fake(nil, { hosts = { [H.TEST_HOST] = { token = function()
    error("keyring locked")
  end } } })
  fake:add(OK)
  local _, err = H.await(get())
  eq(err.kind, "auth")
  eq(err.message:find("keyring locked", 1, true) ~= nil, true)
  eq(#fake:requests(), 0)
  H.fake(nil, { hosts = { [H.TEST_HOST] = { token = function()
    return ""
  end } } })
  local _, err2 = H.await(get())
  eq(err2.kind, "auth")
end

T["GITLAB_TOKEN for listed hosts without a token"] = function()
  vim.env.GITLAB_TOKEN = "env-token-value"
  local fake = H.fake(nil, { hosts = { [H.TEST_HOST] = {} } })
  fake:add(OK)
  H.await(get())
  eq(fake:last().headers["PRIVATE-TOKEN"], "env-token-value")
end

T["config token wins over GITLAB_TOKEN"] = function()
  vim.env.GITLAB_TOKEN = "env-token-value"
  local fake = H.fake()
  fake:add(OK)
  H.await(get())
  eq(fake:last().headers["PRIVATE-TOKEN"], H.TEST_TOKEN)
end

T["unconfigured hosts get no request at all (so no GITLAB_TOKEN either)"] = function()
  vim.env.GITLAB_TOKEN = "env-token-value"
  local fake = H.fake()
  fake:add(OK)
  local _, err = H.await(get("other.example.org"))
  eq(err.kind, "validation")
  eq(#fake:requests(), 0)
end

T["auth = false sends no token"] = function()
  local fake = H.fake()
  fake:add(OK)
  H.await(http.request({ host = H.TEST_HOST, url = "https://gitlab.example.com/api/v4/user", auth = false }))
  eq(fake:last().headers["PRIVATE-TOKEN"], nil)
end

T["source()"] = function()
  vim.env.GITLAB_TOKEN = "env-token-value"
  config.setup({ hosts = { a = { token = "x-token" }, b = { token = function() end }, c = {} }, log = { level = "off" } })
  eq(auth.source(config.host("a")), "config")
  eq(auth.source(config.host("b")), "function")
  eq(auth.source(config.host("c")), "env")
  vim.env.GITLAB_TOKEN = nil
  eq(auth.source(config.host("c")), "none")
end

T["401 without a token gives a hint naming the host"] = function()
  local fake = H.fake(nil, { hosts = { [H.TEST_HOST] = {} } })
  fake:add({ request = { path = "/api/v4/user" }, response = { status = 401, body = { message = "401 Unauthorized" } } })
  local _, err = H.await(get())
  eq(err.kind, "auth")
  eq(err.status, 401)
  eq(err.message:find("no token configured for gitlab.example.com", 1, true) ~= nil, true)
end

T["the token never appears in errors or logs, even when echoed"] = function()
  local logged = {}
  local fake = H.fake(nil, { log = { level = "trace", sink = function(level, message, fields)
    table.insert(logged, vim.inspect({ level, message, fields }))
  end } })
  fake:add({
    request = { path = "/api/v4/user" },
    response = { status = 401, body = { message = "token " .. H.TEST_TOKEN .. " is invalid", echo = H.TEST_TOKEN } },
  })
  local _, err = H.await(get())
  eq(err.kind, "auth")
  eq(vim.inspect(err):find(H.TEST_TOKEN, 1, true), nil)
  eq(tostring(err):find(H.TEST_TOKEN, 1, true), nil)
  eq(#logged > 0, true)
  for _, line in ipairs(logged) do
    eq(line:find(H.TEST_TOKEN, 1, true), nil)
  end
  -- the token was sent, so the redaction is what kept it out
  eq(fake:last().headers["PRIVATE-TOKEN"], H.TEST_TOKEN)
end

T["transport errors are redacted with the request's token"] = function()
  local fake = H.fake()
  fake:add({ request = { path = "/api/v4/user" }, response = { error = { kind = "network", message = "proxy said " .. H.TEST_TOKEN } } })
  local _, err = H.await(get())
  eq(err.kind, "network")
  eq(vim.inspect(err):find(H.TEST_TOKEN, 1, true), nil)
end

return T
