local config = require("gg.config")
local log = require("gg.core.log")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.setup({ log = { level = "off" } })
    end,
  },
})

T["defaults"] = function()
  eq(config.setup(), true)
  local c = config.get()
  eq(c.hosts, { ["gitlab.com"] = { base_url = "https://gitlab.com", aliases = {} } })
  eq(c.timeout, { connect = 10, total = 60, stall = 30 })
  eq(c.retry, { max_attempts = 3, base_delay_ms = 500, max_delay_ms = 30000, max_retry_after_s = 60 })
  eq(c.curl.cmd, "curl")
  eq(c.transport.backend, "curl")
  eq(c.log.level, "warn")
  eq(log.level(), "warn")
end

T["merging hosts, timeouts and retry"] = function()
  local ok = config.setup({
    hosts = {
      ["GitLab.Example.com"] = { base_url = "https://gitlab.example.com/gitlab///", aliases = { "SSH.example.com" } },
    },
    timeout = { total = 120 },
    retry = { max_attempts = 5 },
  })
  eq(ok, true)
  local c = config.get()
  eq(c.hosts["gitlab.com"].base_url, "https://gitlab.com")
  eq(c.hosts["gitlab.example.com"].base_url, "https://gitlab.example.com/gitlab")
  eq(c.hosts["gitlab.example.com"].aliases, { "ssh.example.com" })
  eq(c.timeout, { connect = 10, total = 120, stall = 30 })
  eq(c.retry.max_attempts, 5)
  eq(c.retry.base_delay_ms, 500)
end

T["a default host can be removed"] = function()
  config.setup({ hosts = { ["gitlab.com"] = false } })
  eq(config.get().hosts, {})
  eq(config.host("gitlab.com").listed, false)
end

T["host(): listed, alias, unlisted and per-host overrides"] = function()
  config.setup({
    hosts = {
      ["gitlab.example.com"] = {
        token = "tok-123456",
        aliases = { "ssh.example.com" },
        timeout = { total = 5 },
        retry = { max_attempts = 1 },
      },
    },
  })
  local h = config.host("GITLAB.example.com")
  eq(h.name, "gitlab.example.com")
  eq(h.base_url, "https://gitlab.example.com")
  eq(h.token, "tok-123456")
  eq(h.listed, true)
  eq(h.timeout, { connect = 10, total = 5, stall = 30 })
  eq(h.retry.max_attempts, 1)

  local a = config.host("ssh.example.com")
  eq(a.name, "gitlab.example.com")
  eq(a.listed, true)

  local u = config.host("other.example.org")
  eq(u.name, "other.example.org")
  eq(u.base_url, "https://other.example.org")
  eq(u.token, nil)
  eq(u.listed, false)
end

T["host(): rejects non-host values"] = function()
  for _, bad in ipairs({ "https://gitlab.com", "gitlab.com/x", "gitlab.com:443", "", 42 }) do
    local h, err = config.host(bad)
    eq(h, nil)
    eq(err.kind, "validation")
  end
end

T["hosts(): shape for context.parse"] = function()
  config.setup({ hosts = { ["h.example.com"] = { base_url = "https://h.example.com/root", aliases = { "a.example.com" } } } })
  eq(config.hosts()["h.example.com"], { base_url = "https://h.example.com/root", aliases = { "a.example.com" } })
end

local invalid = {
  { "not a table", "nope", "(root)" },
  { "unknown top key", { colour = true }, "colour" },
  { "hosts not a table", { hosts = 1 }, "hosts" },
  { "host with scheme", { hosts = { ["https://x"] = {} } }, "hosts.https://x" },
  { "host with port", { hosts = { ["x.com:8443"] = {} } }, "hosts.x.com:8443" },
  { "unknown host key", { hosts = { ["x.com"] = { url = "y" } } }, "hosts.x.com.url" },
  { "bad base_url", { hosts = { ["x.com"] = { base_url = "ftp://x.com" } } }, "hosts.x.com.base_url" },
  { "bad token type", { hosts = { ["x.com"] = { token = 123 } } }, "hosts.x.com.token" },
  { "bad alias", { hosts = { ["x.com"] = { aliases = { "a b" } } } }, "hosts.x.com.aliases[1]" },
  { "negative timeout", { timeout = { total = -1 } }, "timeout.total" },
  { "unknown timeout key", { timeout = { read = 1 } }, "timeout.read" },
  { "zero attempts", { retry = { max_attempts = 0 } }, "retry.max_attempts" },
  { "fractional attempts", { retry = { max_attempts = 1.5 } }, "retry.max_attempts" },
  { "empty curl cmd", { curl = { cmd = "" } }, "curl.cmd" },
  { "bad backend", { transport = { backend = "wget" } }, "transport.backend" },
  { "bad log level", { log = { level = "loud" } }, "log.level" },
  { "per-host retry", { hosts = { ["x.com"] = { retry = { base_delay_ms = -5 } } } }, "hosts.x.com.retry.base_delay_ms" },
}

for _, c in ipairs(invalid) do
  T["invalid: " .. c[1]] = function()
    local ok, err = config.setup(c[2])
    eq(ok, false)
    eq(err.kind, "validation")
    eq(err.details.key, c[3])
  end
end

T["failure keeps the previous config"] = function()
  config.setup({ timeout = { total = 7 } })
  local ok = config.setup({ timeout = { total = -1 } })
  eq(ok, false)
  eq(config.get().timeout.total, 7)
end

T["get() returns an isolated copy, but shares the backend"] = function()
  local backend = { send = function() end }
  config.setup({ transport = { backend = backend } })
  local c = config.get()
  c.timeout.total = 999
  c.hosts["gitlab.com"].base_url = "https://evil.example.com"
  eq(config.get().timeout.total, 60)
  eq(config.host("gitlab.com").base_url, "https://gitlab.com")
  eq(config.get().transport.backend == backend, true)
  eq(config.backend() == backend, true)
end

T["tokens never appear in validation errors"] = function()
  local ok, err = config.setup({ hosts = { ["x.com"] = { token = "glpat-supersecret", bogus = true } } })
  eq(ok, false)
  eq(vim.inspect(err):find("supersecret", 1, true), nil)
end

return T
