-- The public API never throws: every resource function, called with bad
-- arguments, returns a Task that resolves to a validation error. This walks
-- every module in lua/gg/resources, so later resources are covered too.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      H.fake()
    end,
    post_case = function()
      H.reset()
    end,
  },
})

local function resource_names()
  local out = {}
  for _, file in ipairs(H.files("lua/gg/resources", "%.lua$")) do
    local name = vim.fs.basename(file):gsub("%.lua$", "")
    if name ~= "common" then
      table.insert(out, name)
    end
  end
  return out
end

T["every resource is exported by the facade"] = function()
  local gg = require("gg")
  local missing = {}
  for _, name in ipairs(resource_names()) do
    if gg[name] ~= require("gg.resources." .. name) then
      table.insert(missing, name)
    end
  end
  eq(missing, {})
end

local BAD_ARGS = {
  { "nil", nil },
  { "empty table", {} },
  { "a string", "gitlab.com" },
  { "a bad host", { host = 1 } },
  { "an unknown key", { host = "gitlab.example.com", bogus_argument = true } },
}

T["bad arguments give a validation Task, never a throw"] = function()
  local problems = {}
  for _, name in ipairs(resource_names()) do
    local mod = require("gg.resources." .. name)
    local fns = vim.tbl_keys(mod)
    table.sort(fns)
    for _, fn_name in ipairs(fns) do
      local fn = mod[fn_name]
      if type(fn) == "function" then
        for _, case in ipairs(BAD_ARGS) do
          local label = ("%s.%s(%s)"):format(name, fn_name, case[1])
          local ok, t = pcall(fn, case[2])
          if not ok then
            table.insert(problems, label .. " threw: " .. tostring(t))
          elseif not require("gg.core.task").is_task(t) then
            table.insert(problems, label .. " did not return a Task")
          else
            local _, err = H.await(t)
            if not err or err.kind ~= "validation" then
              table.insert(problems, label .. " -> " .. vim.inspect(err and err.kind))
            end
          end
        end
      end
    end
  end
  eq(problems, {})
end

return T
