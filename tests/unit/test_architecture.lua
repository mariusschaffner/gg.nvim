-- Guards for the fixed decisions in CLAUDE.md. These scan the source tree, so
-- they cover every module added later without changes here.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function sources()
  return H.files("lua/gg", "%.lua$")
end

-- Layer of a gg module. Higher layers may require lower ones (and their own layer).
-- `pure` modules (context, models) may require nothing outside their own folder.
local function classify(mod)
  if mod == "gg" then return { layer = 6 } end
  local top = mod:match("^gg%.([%w_]+)")
  if top == "core" then return { layer = 0 } end
  if top == "config" then return { layer = 1 } end
  if top == "transport" then return { layer = 2 } end
  if top == "rest" or top == "graphql" then return { layer = 3 } end
  if top == "resources" then return { layer = 4 } end
  if top == "health" then return { layer = 5 } end
  if top == "context" or top == "models" then return { pure = top } end
  return { unknown = true }
end

local function requires(src)
  local out = {}
  for name in src:gmatch("require%s*%(?%s*[\"']([%w%._]+)[\"']") do
    table.insert(out, name)
  end
  return out
end

T["every module belongs to a known layer"] = function()
  local bad = {}
  for _, file in ipairs(sources()) do
    if classify(H.module_name(file)).unknown then
      table.insert(bad, file)
    end
  end
  eq(bad, {})
end

T["no module requires a module above it"] = function()
  local bad = {}
  for _, file in ipairs(sources()) do
    local mod = H.module_name(file)
    local me = classify(mod)
    for _, dep in ipairs(requires(H.read(file))) do
      if dep:match("^gg$") or dep:match("^gg%.") then
        local other = classify(dep)
        local ok
        if me.pure then
          ok = other.pure == me.pure
        elseif other.pure then
          ok = true
        else
          ok = other.layer ~= nil and other.layer <= me.layer
        end
        if not ok then
          table.insert(bad, mod .. " -> " .. dep)
        end
      end
    end
  end
  eq(bad, {})
end

T["no blocking calls, shell-outs or git"] = function()
  local banned = {
    { "vim%.wait%s*%(", "vim.wait" },
    { ":wait%s*%(", ":wait()" },
    { "vim%.fn%.system%s*%(", "vim.fn.system" },
    { "vim%.fn%.systemlist%s*%(", "vim.fn.systemlist" },
    { "io%.popen", "io.popen" },
    { "os%.execute", "os.execute" },
    { "{%s*[\"']git[\"']", "git argv" },
  }
  local bad = {}
  for _, file in ipairs(sources()) do
    local src = H.read(file)
    for _, b in ipairs(banned) do
      if src:find(b[1]) then
        table.insert(bad, file .. ": " .. b[2])
      end
    end
  end
  eq(bad, {})
end

T["every public function has LuaLS annotations"] = function()
  local bad = {}
  for _, file in ipairs(sources()) do
    local lines = vim.split((H.read(file):gsub("\r", "")), "\n", { plain = true })
    for i, line in ipairs(lines) do
      local name = line:match("^function ([%w_]+[.:][%w_]+)%s*%(")
        or line:match("^([%w_]+%.[%w_]+)%s*=%s*function%s*%(")
      if name and not name:match("[.:]_") then
        local prev = lines[i - 1] or ""
        if not prev:match("^%s*%-%-%-") then
          table.insert(bad, ("%s:%d %s"):format(file, i, name))
        end
      end
    end
  end
  eq(bad, {})
end

T["every model declares a gg class"] = function()
  local bad = {}
  for _, file in ipairs(H.files("lua/gg/models", "%.lua$")) do
    if not H.read(file):find("%-%-%-@class gg%.") then
      table.insert(bad, file)
    end
  end
  eq(bad, {})
end

return T
