-- Sanitize a recorded API response into a gg fixture.
--
--   nvim -l scripts/sanitize_fixture.lua <input.json> <output.json> [options]
--
-- <input.json> is either a raw API response body, or a fixture
-- ({ meta, request, response }) whose response.body is sanitized.
--
-- Options:
--   --source <text>       meta.source (e.g. "gitlab.com public, 2026-11-06")
--   --method <M>          request.method          (raw body input only)
--   --path <p>            request.path            (raw body input only)
--   --operation <name>    request.operation       (raw body input only)
--   --status <n>          response.status         (default 200)
--   --variables <json>    request.variables       (GraphQL)
--   --query <json>        request.query           (REST, exact match)
--   --headers <json>      response.headers
--   --append 1            append to the fixture array already in <output.json>
--
-- Rules (see tests/fixtures/README.md):
--   * user objects (tables with `username`): username -> user-N,
--     name -> Test User N, avatar -> placeholder, web_url -> instance/user-N
--   * every e-mail address -> userN@example.com
--   * author_name / committer_name -> Test User N
--   * hosts other than gitlab.com / *.example.* -> gitlab.example.com
--   * @mentions of a sanitized username are rewritten
--   * anything that looks like a token aborts the run
local args = _G.arg or {}

local function die(msg)
  io.stderr:write("sanitize_fixture: " .. msg .. "\n")
  os.exit(1)
end

local input, output = args[1], args[2]
if not input or not output then
  die("usage: nvim -l scripts/sanitize_fixture.lua <input.json> <output.json> [--source S] [--method M --path P | --operation O] [--status N]")
end
local opts = {}
local i = 3
while i <= #args do
  local k = args[i]:gsub("^%-%-", "")
  opts[k] = args[i + 1]
  i = i + 2
end

local f = assert(io.open(input, "rb"))
local raw = f:read("*a")
f:close()
local ok, data = pcall(vim.json.decode, raw)
if not ok then
  die("input is not JSON: " .. tostring(data))
end

local fixture
if type(data) == "table" and (data.response ~= nil or data.request ~= nil) then
  fixture = data
else
  fixture = {
    meta = {},
    request = opts.operation and { operation = opts.operation } or { method = opts.method or "GET", path = opts.path or "/" },
    response = { status = tonumber(opts.status or "200"), headers = vim.empty_dict(), body = data },
  }
  if opts.variables then
    fixture.request.variables = vim.json.decode(opts.variables)
  end
  if opts.query then
    fixture.request.query = vim.json.decode(opts.query)
  end
  if opts.headers then
    fixture.response.headers = vim.json.decode(opts.headers)
  end
end
fixture.meta = fixture.meta or {}
if opts.source then
  fixture.meta.source = opts.source
end
fixture.meta.sanitized = true

local users, emails, names = {}, {}, {}
local n_users, n_emails = 0, 0

local function user_index(username)
  if not users[username] then
    n_users = n_users + 1
    users[username] = n_users
  end
  return users[username]
end

local function person(name)
  if not names[name] then
    n_users = n_users + 1
    names[name] = n_users
  end
  return "Test User " .. names[name]
end

local function sanitize_string(s)
  -- "Some Name <mail@host>" (commit trailers, Merged-by:, Co-authored-by:) -> a sanitized name
  s = s:gsub("([^\n:<>\"]-)(%s*<)([%w%._%%+%-]+@[%w%.%-]+%.%a+>)", function(name, sep, rest)
    local trimmed = vim.trim(name)
    if trimmed == "" or trimmed:match("^Test User %d+$") then
      return name .. sep .. rest
    end
    local lead = name:match("^(%s*)") or ""
    return lead .. person(trimmed) .. sep .. rest
  end)
  s = s:gsub("[%w%._%%+%-]+@[%w%.%-]+%.%a+", function(email)
    if email:match("@example%.com$") then
      return email
    end
    if not emails[email] then
      n_emails = n_emails + 1
      emails[email] = n_emails
    end
    return ("user%d@example.com"):format(emails[email])
  end)
  s = s:gsub("(https?://)([%w%.%-]+)", function(scheme, host)
    local h = host:lower()
    if h == "gitlab.com" or h:match("%.example%.com$") or h:match("%.example%.net$") or h:match("%.example%.org$") or h == "example.com" then
      return scheme .. host
    end
    return scheme .. "gitlab.example.com"
  end)
  return s
end

-- first pass: collect usernames so mentions can be rewritten
local function collect(v)
  if type(v) ~= "table" then
    return
  end
  if type(v.username) == "string" then
    user_index(v.username)
  end
  for _, x in pairs(v) do
    collect(x)
  end
end

local function walk(v)
  if type(v) == "string" then
    local s = sanitize_string(v)
    for uname, idx in pairs(users) do
      s = s:gsub("@" .. vim.pesc(uname) .. "%f[^%w_%-%.]", "@user-" .. idx)
    end
    return s
  end
  if type(v) ~= "table" then
    return v
  end
  local is_user = type(v.username) == "string"
  local out = {}
  for k, x in pairs(v) do
    out[k] = walk(x)
  end
  if is_user then
    local idx = user_index(v.username)
    out.username = "user-" .. idx
    if v.name ~= nil then
      out.name = "Test User " .. idx
    end
    for _, key in ipairs({ "avatar_url", "avatarUrl" }) do
      if v[key] ~= nil then
        out[key] = "https://gitlab.example.com/uploads/avatar.png"
      end
    end
    for _, key in ipairs({ "web_url", "webUrl" }) do
      if v[key] ~= nil then
        out[key] = "https://gitlab.example.com/user-" .. idx
      end
    end
    for _, key in ipairs({ "webPath", "web_path" }) do
      if v[key] ~= nil then
        out[key] = "/user-" .. idx
      end
    end
  end
  for _, key in ipairs({ "author_name", "committer_name", "authorName", "committerName" }) do
    if type(v[key]) == "string" then
      out[key] = person(v[key])
    end
  end
  if getmetatable(v) == getmetatable(vim.empty_dict()) and next(out) == nil then
    return vim.empty_dict()
  end
  return out
end

collect(fixture.response and fixture.response.body)
if fixture.response and fixture.response.body ~= nil then
  fixture.response.body = walk(fixture.response.body)
end

-- Stable, readable JSON: 2-space indent, sorted object keys.
local function pretty(v, indent)
  indent = indent or ""
  local inner = indent .. "  "
  if v == vim.NIL or v == nil then
    return "null"
  end
  if type(v) ~= "table" then
    return vim.json.encode(v)
  end
  local is_dict = getmetatable(v) == getmetatable(vim.empty_dict())
  if not is_dict and (next(v) == nil or vim.islist(v)) then
    if next(v) == nil then
      return "[]"
    end
    local parts = {}
    for _, x in ipairs(v) do
      table.insert(parts, inner .. pretty(x, inner))
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end
  local keys = vim.tbl_keys(v)
  table.sort(keys)
  if #keys == 0 then
    return "{}"
  end
  local parts = {}
  for _, k in ipairs(keys) do
    table.insert(parts, inner .. vim.json.encode(tostring(k)) .. ": " .. pretty(v[k], inner))
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local document = fixture
if opts.append == "1" then
  local ef = io.open(output, "rb")
  if ef then
    local existing = vim.json.decode(ef:read("*a"))
    ef:close()
    if existing.request or existing.response then
      existing = { existing }
    end
    table.insert(existing, fixture)
    document = existing
  else
    document = { fixture }
  end
end

local encoded = pretty(document)
for _, pat in ipairs({ "glpat%-", "gloas%-", "glrt%-", "gldt%-", "glcbt%-", "PRIVATE%-TOKEN", "private_token=" }) do
  if encoded:find(pat) then
    die("refusing to write: the fixture still contains a token-like value (" .. pat .. ")")
  end
end

local out = assert(io.open(output, "wb"))
out:write(encoded)
out:write("\n")
out:close()
io.stdout:write(("sanitized %d user(s), %d e-mail(s) -> %s\n"):format(n_users, n_emails, output))
