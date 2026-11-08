local H = require("tests.helpers")
local config = require("gg.config")
local eq = MiniTest.expect.equality

local messages
local saved_health, saved_env

local function capture()
  messages = {}
  local stub = {}
  for _, kind in ipairs({ "start", "ok", "warn", "error", "info" }) do
    stub[kind] = function(msg, advice)
      table.insert(messages, { kind = kind, msg = msg, advice = advice })
    end
  end
  return stub
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved_health = vim.health
      saved_env = os.getenv("GITLAB_TOKEN")
      vim.env.GITLAB_TOKEN = nil
      vim.health = capture()
    end,
    post_case = function()
      vim.health = saved_health
      vim.env.GITLAB_TOKEN = saved_env
      H.reset()
    end,
  },
})

local function run(opts)
  assert(config.setup(vim.tbl_extend("force", { log = { level = "off" } }, opts or {})))
  require("gg.health").check()
  return messages
end

local function find(kind, pattern)
  for _, m in ipairs(messages) do
    if m.kind == kind and m.msg:find(pattern) then
      return m
    end
  end
end

T["requirements and configuration"] = function()
  run()
  eq(find("ok", "^Neovim ") ~= nil, true)
  eq(find("ok", "^curl found: ") ~= nil, true)
  eq(find("ok", "^configuration is valid") ~= nil, true)
  eq(find("ok", "^transport backend: curl") ~= nil, true)
  eq(find("info", "^logging is off") ~= nil, true)
  local starts = vim.tbl_map(function(m)
    return m.msg
  end, vim.tbl_filter(function(m)
    return m.kind == "start"
  end, messages))
  eq(starts, { "gg: requirements", "gg: configuration", "gg: hosts" })
end

T["missing curl is an error"] = function()
  run({ curl = { cmd = "gg-no-such-curl-binary" } })
  eq(find("error", "curl not found") ~= nil, true)
end

T["no token is a warning; http is a warning"] = function()
  run({ hosts = { ["git.example.com"] = { base_url = "http://git.example.com" } } })
  eq(find("warn", "git%.example%.com: no token") ~= nil, true)
  eq(find("warn", "plain http") ~= nil, true)
end

T["token sources, never the value; token functions are not called"] = function()
  local called = false
  vim.env.GITLAB_TOKEN = "env-secret-value-123"
  run({
    hosts = {
      ["a.example.com"] = { token = "config-secret-value-456" },
      ["b.example.com"] = { token = function()
        called = true
        return "fn-secret-value-789"
      end },
      ["c.example.com"] = {},
    },
  })
  eq(find("ok", "a%.example%.com: token from config") ~= nil, true)
  eq(find("ok", "b%.example%.com: token from a function") ~= nil, true)
  eq(find("ok", "c%.example%.com: token from GITLAB_TOKEN") ~= nil, true)
  eq(called, false)
  local all = vim.inspect(messages)
  for _, secret in ipairs({ "env-secret-value-123", "config-secret-value-456", "fn-secret-value-789" }) do
    eq(all:find(secret, 1, true), nil)
  end
end

T["a non-curl backend is a warning; log level is reported"] = function()
  run({ transport = { backend = { send = function() end } }, log = { level = "debug", sink = function() end } })
  eq(find("warn", "not curl") ~= nil, true)
  eq(find("info", "log level: debug %(writing to a custom sink%)") ~= nil, true)
end

T["no listed hosts"] = function()
  run({ hosts = {} })
  eq(find("warn", "no GitLab host is configured") ~= nil, true)
end

return T
