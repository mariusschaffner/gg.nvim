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
  -- the UI sits above the facade and talks to the API only through `gg`
  if top == "ui" then return { layer = 7, ui = true } end
  if top == "context" or top == "models" then return { pure = top } end
  return { unknown = true }
end

-- Code without comment lines (doc comments may show usage like require("gg")).
local function code_only(src)
  local out = {}
  for line in (src:gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
    if not line:match("^%s*%-%-") then
      table.insert(out, line)
    end
  end
  return table.concat(out, "\n")
end

local function requires(src)
  local out = {}
  for name in code_only(src):gmatch("require%s*%(?%s*[\"']([%w%._]+)[\"']") do
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
        if me.ui then
          ok = dep == "gg" or other.ui == true
        elseif me.pure then
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
  -- the UI resolves the project from the git remote (async), only here
  local git_allowed = { ["lua/gg/ui/project.lua"] = true }
  local bad = {}
  for _, file in ipairs(sources()) do
    local src = code_only(H.read(file))
    for _, b in ipairs(banned) do
      if src:find(b[1]) and not (b[2] == "git argv" and git_allowed[file]) then
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

T["gg is standalone: no references to the old plugin"] = function()
  local bad = {}
  for _, dir in ipairs({ "lua/gg", "tests", "scripts" }) do
    for _, file in ipairs(H.files(dir, "%.lua$")) do
      for n, line in ipairs(vim.split(H.read(file), "\n", { plain = true })) do
        -- built from parts so this test does not match itself
        if line:lower():find("at" .. "las", 1, true) then
          table.insert(bad, ("%s:%d"):format(file, n))
        end
      end
    end
  end
  eq(bad, {})
end

T["pure UI modules do not touch vim.api"] = function()
  local pure = { "lua/gg/ui/lib", "lua/gg/ui/issues/filter.lua", "lua/gg/ui/issues/model.lua",
    "lua/gg/ui/issues/paginate.lua", "lua/gg/ui/issues/columns.lua", "lua/gg/ui/issues/render.lua",
    "lua/gg/ui/components/tabs.lua", "lua/gg/ui/components/columns.lua", "lua/gg/ui/components/grid.lua",
    "lua/gg/ui/components/queue.lua", "lua/gg/ui/merge_requests/filter.lua", "lua/gg/ui/merge_requests/model.lua",
    "lua/gg/ui/merge_requests/columns.lua", "lua/gg/ui/merge_requests/cells.lua", "lua/gg/ui/merge_requests/render.lua",
    "lua/gg/ui/pipelines/filter.lua", "lua/gg/ui/pipelines/model.lua", "lua/gg/ui/pipelines/columns.lua",
    "lua/gg/ui/pipelines/render.lua" }
  local bad = {}
  for _, file in ipairs(sources()) do
    for _, prefix in ipairs(pure) do
      if file:sub(1, #prefix) == prefix and code_only(H.read(file)):find("vim%.api") then
        table.insert(bad, file)
      end
    end
  end
  eq(bad, {})
end

T["only the UI requires gg.ui"] = function()
  local bad = {}
  for _, file in ipairs(sources()) do
    if not file:find("^lua/gg/ui/") then
      for _, dep in ipairs(requires(H.read(file))) do
        if dep:match("^gg%.ui") then
          table.insert(bad, file .. " -> " .. dep)
        end
      end
    end
  end
  eq(bad, {})
end

T["every model declares a gg class"] = function()
  local bad = {}
  -- gid.lua and util.lua are mapper helpers, not models
  local helpers = { ["lua/gg/models/gid.lua"] = true, ["lua/gg/models/util.lua"] = true }
  for _, file in ipairs(H.files("lua/gg/models", "%.lua$")) do
    if not helpers[file] and not H.read(file):find("%-%-%-@class gg%.") then
      table.insert(bad, file)
    end
  end
  eq(bad, {})
end

return T
