-- The help file builds cleanly and documents the whole public API, and the
-- README lists every resource.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

-- every function reachable from require("gg"), as "gg.a.b"
local function public_functions()
  local out = {}
  local seen = {}
  local function walk(tbl, prefix, depth)
    if seen[tbl] or depth > 3 then
      return
    end
    seen[tbl] = true
    for k, v in pairs(tbl) do
      local name = prefix .. "." .. k
      if type(v) == "function" then
        table.insert(out, name)
      elseif type(v) == "table" and type(k) == "string" and not k:match("^%u") then
        walk(v, name, depth + 1)
      end
    end
  end
  walk(require("gg"), "gg", 1)
  table.sort(out)
  return out
end

T["helptags builds without errors or duplicate tags"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/doc", "p")
  vim.fn.writefile(vim.fn.readfile(H.path("doc/gg.txt")), dir .. "/doc/gg.txt")
  local ok, err = pcall(vim.cmd.helptags, dir .. "/doc")
  eq(ok, true, err)
  local tags = vim.fn.readfile(dir .. "/doc/tags")
  eq(#tags > 100, true)
  local names = {}
  for _, line in ipairs(tags) do
    local tag = line:match("^([^\t]+)")
    eq(names[tag], nil)
    names[tag] = true
  end
  vim.fn.delete(dir, "rf")
end

T["every public function has a help tag"] = function()
  local doc = H.read("doc/gg.txt")
  local missing = {}
  for _, name in ipairs(public_functions()) do
    if not doc:find("*" .. name .. "()*", 1, true) then
      table.insert(missing, name)
    end
  end
  eq(missing, {})
end

T["the README lists every resource"] = function()
  local readme = H.read("README.md")
  local missing = {}
  for _, file in ipairs(H.files("lua/gg/resources", "%.lua$")) do
    local name = vim.fs.basename(file):gsub("%.lua$", "")
    if name ~= "common" and not readme:find("`gg." .. name .. "`", 1, true) then
      table.insert(missing, name)
    end
  end
  eq(missing, {})
end

return T
