--- `:checkhealth gg`
---
--- Runs synchronously, so it makes no network calls and starts no processes
--- (no blocking). It reports what can be known locally: Neovim, curl, the
--- configuration, and per host the URL scheme and where the token comes from.
--- Token values are never printed; a token function is never called.
local auth = require("gg.transport.auth")
local config = require("gg.config")
local log = require("gg.core.log")

local M = {}

local function report_requirements(h)
  h.start("gg: requirements")
  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.10 or newer is required")
  end
  local cmd = config.curl_cmd()
  if vim.fn.executable(cmd) == 1 then
    h.ok(("curl found: %s"):format(vim.fn.exepath(cmd)))
  else
    h.error(("curl not found (config.curl.cmd = %q)"):format(cmd), { "Install curl, or set `curl = { cmd = ... }` in gg.setup()" })
  end
end

local function report_config(h)
  h.start("gg: configuration")
  local cfg = config.get()
  local err = config.validate({ timeout = cfg.timeout, retry = cfg.retry, curl = cfg.curl })
  if err then
    h.error("configuration is invalid: " .. err.message)
  else
    h.ok("configuration is valid")
  end
  if config.backend() == "curl" then
    h.ok("transport backend: curl")
  else
    h.warn("transport backend is not curl (a test or custom backend is configured)")
  end
  local level = log.level()
  if level == "off" then
    h.info("logging is off")
  else
    local sink = cfg.log.sink and "a custom sink" or (cfg.log.file or vim.fs.joinpath(vim.fn.stdpath("log"), "gg.log"))
    h.info(("log level: %s (writing to %s)"):format(level, sink))
  end
end

local SOURCES = {
  config = "token from config",
  ["function"] = "token from a function (not called by :checkhealth)",
  env = "token from " .. auth.ENV,
}

local function report_hosts(h)
  h.start("gg: hosts")
  local names = vim.tbl_keys(config.get().hosts)
  table.sort(names)
  if #names == 0 then
    h.warn("no GitLab host is configured, so every request fails", {
      'Add your instance: gg.setup({ hosts = { ["gitlab.example.com"] = { token = ... } } })',
    })
    return
  end
  for _, name in ipairs(names) do
    local s = config.host(name)
    if s then
      if s.base_url:match("^[hH][tT][tT][pP]://") then
        h.warn(("%s: %s uses plain http, so the token is sent unencrypted"):format(name, s.base_url))
      else
        h.ok(("%s: %s"):format(name, s.base_url))
      end
      local source = auth.source(s)
      if source == "none" then
        h.warn(("%s: no token, so only public data can be read"):format(name), {
          ("Set hosts[%q].token in gg.setup(), or %s"):format(name, auth.ENV),
        })
      else
        h.ok(("%s: %s"):format(name, SOURCES[source]))
      end
    end
  end
end

--- Entry point for `:checkhealth gg`.
function M.check()
  local h = vim.health
  report_requirements(h)
  report_config(h)
  report_hosts(h)
end

return M
