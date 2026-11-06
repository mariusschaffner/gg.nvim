local H = require("tests.helpers")
local log = require("gg.core.log")
local redact = require("gg.core.redact")
local eq = MiniTest.expect.equality

local captured

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      captured = {}
      log.configure({
        level = "debug",
        sink = function(level, message, fields)
          table.insert(captured, { level = level, message = message, fields = fields })
        end,
      })
    end,
    post_case = function()
      log.configure({ level = "off" })
    end,
  },
})

T["levels filter messages"] = function()
  log.trace("hidden")
  log.debug("shown")
  log.error("also shown")
  eq(#captured, 2)
  eq(captured[1].level, "debug")
  eq(captured[2].level, "error")
  log.configure({
    level = "error",
    sink = function(l, m)
      table.insert(captured, { level = l, message = m })
    end,
  })
  log.warn("hidden now")
  eq(#captured, 2)
end

T["off disables everything"] = function()
  log.configure({ level = "off", sink = function()
    error("must not be called")
  end })
  log.error("x")
  eq(log.enabled("error"), false)
end

T["default level is warn"] = function()
  log.configure({})
  eq(log.level(), "warn")
  eq(log.enabled("info"), false)
  eq(log.enabled("warn"), true)
end

T["messages and fields are redacted"] = function()
  log.debug("sending PRIVATE-TOKEN: glpat-secret", { headers = { ["PRIVATE-TOKEN"] = "abc" }, url = "https://h/?private_token=zzz" })
  eq(captured[1].message, "sending PRIVATE-TOKEN: " .. redact.MASK)
  eq(captured[1].fields.headers["PRIVATE-TOKEN"], redact.MASK)
  eq(captured[1].fields.url, "https://h/?private_token=" .. redact.MASK)
end

T["fields are lazy"] = function()
  local called = 0
  local fields = function()
    called = called + 1
    return { a = 1 }
  end
  log.trace("hidden", fields)
  eq(called, 0)
  log.debug("shown", fields)
  eq(called, 1)
  eq(captured[1].fields, { a = 1 })
end

T["a failing sink or fields function never throws"] = function()
  log.configure({ level = "debug", sink = function()
    error("sink broke")
  end })
  log.error("x")
  log.configure({ level = "debug", sink = function(_, _, f)
    captured.f = f
  end })
  log.debug("y", function()
    error("fields broke")
  end)
  eq(type(captured.f.fields_error), "string")
end

T["configure validates"] = function()
  local ok, err = log.configure({ level = "loud" })
  eq(ok, false)
  eq(err.kind, "validation")
  eq(err.details.key, "log.level")
  ok, err = log.configure({ sink = "nope" })
  eq(ok, false)
  eq(err.details.key, "log.sink")
end

T["file sink appends formatted lines"] = function()
  local path = vim.fn.tempname() .. "-gg.log"
  log.configure({ level = "info", file = path })
  log.info("first", { b = 2, a = 1 })
  log.warn("second token=glpat-zzz")
  H.wait_for(function()
    local f = io.open(path, "r")
    if not f then
      return false
    end
    local data = f:read("*a")
    f:close()
    return select(2, data:gsub("\n", "")) >= 2
  end)
  local data = H.read(path)
  eq(data:find("%[INFO%] first a=1 b=2") ~= nil, true)
  eq(data:find("%[WARN%] second") ~= nil, true)
  eq(data:find("glpat", 1, true), nil)
  os.remove(path)
end

return T
