-- Every fixture must be sanitized (CLAUDE.md "Testing"): no tokens, no real
-- e-mails, no internal host names, no personal names. This scans every file,
-- so fixtures added later are covered automatically.
local H = require("tests.helpers")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function fixture_files()
  return H.files("tests/fixtures", "%.json$")
end

local TOKEN_PATTERNS = { "glpat%-", "gloas%-", "glrt%-", "gldt%-", "glcbt%-", "glptt%-", "glft%-", "PRIVATE%-TOKEN", "private_token=", "job_token=" }

local function host_allowed(host)
  host = host:lower()
  return host == "gitlab.com"
    or host == "example.com"
    or host == "127.0.0.1"
    or host:match("%.example%.com$") ~= nil
    or host:match("%.example%.net$") ~= nil
    or host:match("%.example%.org$") ~= nil
end

local function walk(v, visit, path)
  path = path or "$"
  visit(v, path)
  if type(v) == "table" then
    for k, x in pairs(v) do
      walk(x, visit, path .. "." .. tostring(k))
    end
  end
end

T["fixtures exist and decode"] = function()
  local bad = {}
  for _, file in ipairs(fixture_files()) do
    local ok, data = pcall(vim.json.decode, H.read(file))
    if not ok then
      table.insert(bad, file .. ": " .. tostring(data))
    else
      local list = (data.request or data.response) and { data } or data
      for i, fx in ipairs(list) do
        if type(fx.request) ~= "table" or type(fx.response) ~= "table" then
          table.insert(bad, ("%s[%d]: needs request and response"):format(file, i))
        end
        if type(fx.meta) ~= "table" or type(fx.meta.source) ~= "string" then
          table.insert(bad, ("%s[%d]: needs meta.source"):format(file, i))
        end
        local p = type(fx.request) == "table" and fx.request.path
        if p ~= nil and (type(p) ~= "string" or p:sub(1, 1) ~= "/" or p:find(":", 1, true)) then
          table.insert(bad, ("%s[%d]: request.path must be a raw URL path starting with /"):format(file, i))
        end
      end
    end
  end
  eq(bad, {})
end

T["no token-like values"] = function()
  local bad = {}
  for _, file in ipairs(fixture_files()) do
    local text = H.read(file)
    for _, pat in ipairs(TOKEN_PATTERNS) do
      if text:find(pat) then
        table.insert(bad, file .. ": " .. pat)
      end
    end
  end
  eq(bad, {})
end

T["e-mail addresses are only at example.com"] = function()
  local bad = {}
  for _, file in ipairs(fixture_files()) do
    for email in H.read(file):gmatch("[%w%._%%+%-]+@[%w%.%-]+%.%a+") do
      if not email:match("@example%.com$") then
        table.insert(bad, file .. ": " .. email)
      end
    end
  end
  eq(bad, {})
end

T["@mentions are sanitized"] = function()
  local bad = {}
  for _, file in ipairs(fixture_files()) do
    -- drop e-mail addresses first, then look for @name mentions
    local text = H.read(file):gsub("[%w%._%%+%-]+@[%w%.%-]+%.%a+", "")
    for name in text:gmatch("%f[%w@]@([%w][%w_%.%-]*[%w])") do
      if not name:match("^user%-%d+$") then
        table.insert(bad, file .. ": @" .. name)
      end
    end
  end
  eq(bad, {})
end

T["URL hosts are public or example hosts"] = function()
  local bad = {}
  for _, file in ipairs(fixture_files()) do
    for host in H.read(file):gmatch("https?://([%w%.%-]+)") do
      if not host_allowed(host) then
        table.insert(bad, file .. ": " .. host)
      end
    end
  end
  eq(bad, {})
end

T["user objects and commit authors are sanitized"] = function()
  local bad = {}
  for _, file in ipairs(fixture_files()) do
    walk(vim.json.decode(H.read(file)), function(v, path)
      if type(v) ~= "table" then
        return
      end
      if type(v.username) == "string" then
        if not v.username:match("^user%-%d+$") then
          table.insert(bad, ("%s %s.username = %s"):format(file, path, v.username))
        end
        if type(v.name) == "string" and not v.name:match("^Test User %d+$") then
          table.insert(bad, ("%s %s.name = %s"):format(file, path, v.name))
        end
      end
      for _, key in ipairs({ "author_name", "committer_name", "authorName", "committerName" }) do
        if type(v[key]) == "string" and not v[key]:match("^Test User %d+$") then
          table.insert(bad, ("%s %s.%s = %s"):format(file, path, key, v[key]))
        end
      end
    end)
  end
  eq(bad, {})
end

T["the sanitizer rewrites users, e-mails, hosts and refuses tokens"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local input = dir .. "/raw.json"
  local output = dir .. "/out.json"
  local raw = {
    {
      id = 1,
      description = "ping @jdoe, mail jane.doe@corp.internal, see https://git.corp.internal/x",
      author = { id = 7, username = "jdoe", name = "Jane Doe", avatar_url = "https://secure.gravatar.example.org/a", web_url = "https://git.corp.internal/jdoe" },
      commit = { author_name = "Jane Doe", author_email = "jane.doe@corp.internal" },
    },
  }
  local f = assert(io.open(input, "wb"))
  f:write(vim.json.encode(raw))
  f:close()
  local res = vim.system({ vim.v.progpath, "-l", H.path("scripts/sanitize_fixture.lua"), input, output, "--source", "unit test", "--path", "/api/v4/x" }):wait()
  eq(res.code, 0)
  local fx = vim.json.decode(H.read(output))
  eq(fx.meta, { source = "unit test", sanitized = true })
  eq(fx.request, { method = "GET", path = "/api/v4/x" })
  local item = fx.response.body[1]
  eq(item.author.username, "user-1")
  eq(item.author.name, "Test User 1")
  eq(item.author.avatar_url, "https://gitlab.example.com/uploads/avatar.png")
  eq(item.author.web_url, "https://gitlab.example.com/user-1")
  eq(item.description, "ping @user-1, mail user1@example.com, see https://gitlab.example.com/x")
  eq(item.commit.author_name:match("^Test User %d+$") ~= nil, true)
  eq(item.commit.author_email, "user1@example.com")

  -- a token aborts
  f = assert(io.open(input, "wb"))
  f:write(vim.json.encode({ note = "glpat-" .. "abcdefghijklmnop" }))
  f:close()
  local bad = vim.system({ vim.v.progpath, "-l", H.path("scripts/sanitize_fixture.lua"), input, dir .. "/bad.json" }):wait()
  eq(bad.code ~= 0, true)
  eq(vim.uv.fs_stat(dir .. "/bad.json"), nil)
  vim.fn.delete(dir, "rf")
end

return T
