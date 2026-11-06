local context = require("gg.context")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local HOSTS = {
  ["gitlab.example.com"] = { base_url = "https://gitlab.example.com", aliases = { "ssh.gitlab.example.com" } },
  ["example.org"] = { base_url = "https://example.org/gitlab", aliases = {} },
  ["git.example.net"] = { base_url = "https://git.example.net:8443", aliases = {} },
}

local function R(host, project, scheme, base_url, port)
  return { host = host, project = project, scheme = scheme, base_url = base_url, port = port }
end

local ok_cases = {
  { "git@gitlab.com:group/repo.git", nil, R("gitlab.com", "group/repo", "ssh", "https://gitlab.com") },
  { "git@gitlab.com:group/sub/sub2/repo.git", nil, R("gitlab.com", "group/sub/sub2/repo", "ssh", "https://gitlab.com") },
  { "gitlab.com:group/repo", nil, R("gitlab.com", "group/repo", "ssh", "https://gitlab.com") },
  { "ssh://git@gitlab.example.com:2222/group/repo.git", nil, R("gitlab.example.com", "group/repo", "ssh", "https://gitlab.example.com", 2222) },
  { "ssh://git@gitlab.example.com/group/repo.git", nil, R("gitlab.example.com", "group/repo", "ssh", "https://gitlab.example.com") },
  { "git+ssh://git@gitlab.com/g/r.git", nil, R("gitlab.com", "g/r", "ssh", "https://gitlab.com") },
  { "https://gitlab.com/group/repo.git", nil, R("gitlab.com", "group/repo", "https", "https://gitlab.com") },
  { "https://gitlab.com/group/repo", nil, R("gitlab.com", "group/repo", "https", "https://gitlab.com") },
  { "https://gitlab.com/group/repo/", nil, R("gitlab.com", "group/repo", "https", "https://gitlab.com") },
  { "https://gitlab.com/group/repo.git/", nil, R("gitlab.com", "group/repo", "https", "https://gitlab.com") },
  { "https://gitlab.example.com:8443/group/repo.git", nil, R("gitlab.example.com", "group/repo", "https", "https://gitlab.example.com:8443", 8443) },
  { "http://gitlab.example.com/group/repo.git", nil, R("gitlab.example.com", "group/repo", "http", "http://gitlab.example.com") },
  { "git://gitlab.example.com/group/repo.git", nil, R("gitlab.example.com", "group/repo", "git", "https://gitlab.example.com") },
  { "https://oauth2:secret-pass@gitlab.com/group/repo.git", nil, R("gitlab.com", "group/repo", "https", "https://gitlab.com") },
  { "https://user@gitlab.com/group/repo.git", nil, R("gitlab.com", "group/repo", "https", "https://gitlab.com") },
  { "HTTPS://GitLab.COM/Group/Repo.git", nil, R("gitlab.com", "Group/Repo", "https", "https://gitlab.com") },
  { "  git@gitlab.com:group/repo.git\n", nil, R("gitlab.com", "group/repo", "ssh", "https://gitlab.com") },
  { "https://gitlab.com/group/my%20repo.git", nil, nil },
  { "https://gitlab.com/group/repo.git?x=1#frag", nil, R("gitlab.com", "group/repo", "https", "https://gitlab.com") },
  { "git@ssh.gitlab.example.com:group/repo.git", HOSTS, R("gitlab.example.com", "group/repo", "ssh", "https://gitlab.example.com") },
  { "https://example.org/gitlab/group/repo.git", HOSTS, R("example.org", "group/repo", "https", "https://example.org/gitlab") },
  { "git@example.org:group/repo.git", HOSTS, R("example.org", "group/repo", "ssh", "https://example.org/gitlab") },
  { "ssh://git@git.example.net:2222/group/repo.git", HOSTS, R("git.example.net", "group/repo", "ssh", "https://git.example.net:8443", 2222) },
  { "ssh://git@[::1]:2222/group/repo.git", nil, R("[::1]", "group/repo", "ssh", "https://[::1]", 2222) },
  { "git@[::1]:group/repo.git", nil, R("[::1]", "group/repo", "ssh", "https://[::1]") },
  { "https://gitlab.com/group/repo.git.git", nil, R("gitlab.com", "group/repo.git", "https", "https://gitlab.com") },
}

for _, c in ipairs(ok_cases) do
  T["parses " .. vim.trim(c[1])] = function()
    local r, err = context.parse(c[1], c[2] and { hosts = c[2] } or nil)
    if c[3] == nil then
      eq(r, nil)
      eq(err.kind, "validation")
    else
      eq(err, nil)
      eq(r, c[3])
    end
  end
end

local bad_cases = {
  "",
  "   ",
  "not a url",
  "git@gitlab.com:repo.git",
  "https://gitlab.com/repo.git",
  "https://gitlab.com/",
  "file:///home/me/repo.git",
  "/home/me/repo",
  "./repo",
  "C:\\work\\repo",
  "ftp://gitlab.com/g/r.git",
  "git@gitlab.com:g/../r.git",
  "https://gitlab.com/g//r",
}

for _, url in ipairs(bad_cases) do
  T[("rejects %q"):format(url)] = function()
    local r, err = context.parse(url)
    eq(r, nil)
    eq(err.kind, "validation")
    eq(type(err.message), "string")
  end
end

T["rejects non-strings"] = function()
  eq(select(2, context.parse(nil)).kind, "validation")
  eq(select(2, context.parse(42)).kind, "validation")
end

T["credentials never appear in the result or the error"] = function()
  local r = context.parse("https://oauth2:glpat-xyz123@gitlab.com/g/r.git")
  eq(vim.inspect(r):find("glpat", 1, true), nil)
  local _, err = context.parse("https://oauth2:glpat-xyz123@gitlab.com/onlyrepo")
  eq(vim.inspect(err):find("glpat", 1, true), nil)
end

T["works with gg.config.hosts()"] = function()
  local config = require("gg.config")
  config.setup({ hosts = { ["example.org"] = { base_url = "https://example.org/gitlab", aliases = { "ssh.example.org" } } }, log = { level = "off" } })
  local r = context.parse("git@ssh.example.org:group/repo.git", { hosts = config.hosts() })
  eq(r.host, "example.org")
  eq(r.base_url, "https://example.org/gitlab")
  config.setup({ log = { level = "off" } })
end

return T
