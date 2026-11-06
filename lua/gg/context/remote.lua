--- Parse git remote URLs into a host and a project path.
---
--- Pure: no git calls, no config access, no gg requires. Callers pass the
--- known hosts (e.g. `gg.config.hosts()`) to resolve aliases and relative
--- URL roots. Credentials in a URL are stripped and never returned.
local M = {}

---@class gg.Remote
---@field host string canonical host name, lowercase, without port
---@field port integer|nil port as written in the URL (SSH or HTTP)
---@field scheme "ssh"|"https"|"http"|"git"
---@field project string full project path, e.g. "group/sub/repo"
---@field base_url string API base URL for the instance, e.g. "https://gitlab.example.com"

---@class gg.KnownHost
---@field base_url? string
---@field aliases? string[]

---@class gg.ContextOptions
---@field hosts? table<string, gg.KnownHost> known hosts (the shape of `gg.config.hosts()`)

local SCHEMES = {
  ssh = "ssh",
  ["git+ssh"] = "ssh",
  ["ssh+git"] = "ssh",
  https = "https",
  http = "http",
  git = "git",
}

local function fail(message, details)
  return nil, { kind = "validation", message = message, details = details or {} }
end

local function decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- Find the known host for a name (directly or through an alias).
---@param name string lowercase host name
---@param hosts table<string, gg.KnownHost>|nil
---@return string canonical
---@return gg.KnownHost|nil
function M.known_host(name, hosts)
  if not hosts then
    return name, nil
  end
  for hname, h in pairs(hosts) do
    if hname:lower() == name then
      return hname:lower(), h
    end
  end
  for hname, h in pairs(hosts) do
    for _, alias in ipairs(type(h) == "table" and h.aliases or {}) do
      if alias:lower() == name then
        return hname:lower(), h
      end
    end
  end
  return name, nil
end

--- The path of a base URL ("https://h/gitlab" -> "/gitlab", "" when none).
---@param base_url string|nil
---@return string
function M.root_of(base_url)
  if type(base_url) ~= "string" then
    return ""
  end
  local path = base_url:match("^%a[%w+%.%-]*://[^/]+(/.*)$") or ""
  return (path:gsub("/+$", ""))
end

-- split "host[:port]" or "[v6][:port]"
local function split_host_port(authority)
  local v6, rest = authority:match("^(%[[%x:%.]+%])(.*)$")
  if v6 then
    local port = rest:match("^:(%d+)$")
    if rest ~= "" and not port then
      return nil
    end
    return v6:lower(), port and tonumber(port) or nil
  end
  local host, port = authority:match("^([^:]+):(%d*)$")
  if host then
    return host:lower(), port ~= "" and tonumber(port) or nil
  end
  if authority:find(":", 1, true) then
    return nil
  end
  return authority:lower(), nil
end

local function clean_project(path)
  path = decode(path)
  path = path:gsub("[?#].*$", "")
  path = path:gsub("^/+", ""):gsub("/+$", "")
  path = path:gsub("%.git$", "")
  path = path:gsub("/+$", "")
  return path
end

local function valid_project(path)
  if path == "" or path:find("//", 1, true) or path:match("%s") then
    return false
  end
  local n = 0
  for seg in path:gmatch("[^/]+") do
    if seg == "." or seg == ".." then
      return false
    end
    n = n + 1
  end
  return n >= 2
end

--- Parse a remote URL.
---@param url string
---@param opts? gg.ContextOptions
---@return gg.Remote|nil
---@return gg.Error|nil err a plain table { kind = "validation", message, details }
function M.parse(url, opts)
  opts = opts or {}
  if type(url) ~= "string" then
    return fail("remote URL must be a string")
  end
  url = vim.trim(url)
  if url == "" then
    return fail("remote URL is empty")
  end
  if url:match("^%a:[/\\]") or url:match("^[/\\.~]") or url:match("^[Ff][Ii][Ll][Ee]://") then
    return fail("local paths are not GitLab remotes")
  end

  local scheme, authority, path
  local s, rest = url:match("^(%a[%w+%.%-]*)://(.*)$")
  if s then
    scheme = SCHEMES[s:lower()]
    if not scheme then
      return fail("unsupported remote URL scheme: " .. s:lower())
    end
    authority, path = rest:match("^([^/]*)(.*)$")
    authority = authority:gsub("^.*@", "")
  else
    -- scp-like: [user@]host:path (no slash before the colon), or [user@][v6]:path
    local userhost, p = url:match("^([^/]-%[[%x:%.]+%]):(.+)$")
    if not userhost then
      userhost, p = url:match("^([^/]-):(.+)$")
    end
    if not userhost or userhost == "" then
      return fail("not a remote URL")
    end
    local host_part = userhost:gsub("^.*@", "")
    if host_part:match("^%[.*%]$") then
      authority = host_part
    elseif host_part:find(":", 1, true) or host_part == "" then
      return fail("not a remote URL")
    else
      authority = host_part
    end
    scheme = "ssh"
    path = p
  end

  local host, port = split_host_port(authority or "")
  if not host or host == "" then
    return fail("remote URL has no host")
  end

  local canonical, known = M.known_host(host, opts.hosts)
  local project = clean_project(path or "")

  local base_url
  if known and known.base_url then
    base_url = known.base_url:gsub("/+$", "")
    if scheme == "https" or scheme == "http" then
      local root = M.root_of(base_url)
      if root ~= "" then
        local stripped_root = root:gsub("^/", "")
        if project == stripped_root or project:sub(1, #stripped_root + 1) == stripped_root .. "/" then
          project = project:sub(#stripped_root + 2)
        end
      end
    end
  elseif scheme == "https" or scheme == "http" then
    base_url = scheme .. "://" .. canonical .. (port and (":" .. port) or "")
  else
    base_url = "https://" .. canonical
  end

  if not valid_project(project) then
    return fail("remote URL has no group/project path", { host = canonical })
  end

  return {
    host = canonical,
    port = port,
    scheme = scheme,
    project = project,
    base_url = base_url,
  }, nil
end

return M
