local context = require("gg.context")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local HOSTS = { ["example.org"] = { base_url = "https://example.org/gitlab", aliases = {} } }

local function W(kind, project, extra, host, base)
  local t = { kind = kind, project = project, host = host or "gitlab.com", base_url = base or "https://gitlab.com" }
  for k, v in pairs(extra or {}) do
    t[k] = v
  end
  return t
end

local ok_cases = {
  { "https://gitlab.com/group/repo/-/issues/12", W("issue", "group/repo", { iid = 12 }) },
  { "https://gitlab.com/group/sub/repo/-/merge_requests/3", W("merge_request", "group/sub/repo", { iid = 3 }) },
  { "https://gitlab.com/group/repo/-/merge_requests/3/diffs", W("merge_request", "group/repo", { iid = 3 }) },
  { "https://gitlab.com/group/repo/-/merge_requests/3/pipelines?x=1#note_9", W("merge_request", "group/repo", { iid = 3 }) },
  { "https://gitlab.com/group/repo/-/pipelines/9001", W("pipeline", "group/repo", { id = 9001 }) },
  { "https://gitlab.com/group/repo/-/jobs/77", W("job", "group/repo", { id = 77 }) },
  { "https://gitlab.com/group/repo/-/milestones/2", W("milestone", "group/repo", { iid = 2 }) },
  { "https://gitlab.com/group/repo/-/work_items/5", W("work_item", "group/repo", { iid = 5 }) },
  { "https://gitlab.com/group/repo", W("project", "group/repo") },
  { "https://gitlab.com/group/repo/", W("project", "group/repo") },
  { "https://gitlab.com/group/repo/issues/12", W("issue", "group/repo", { iid = 12 }) },
  { "https://example.org/gitlab/group/repo/-/issues/4", W("issue", "group/repo", { iid = 4 }, "example.org", "https://example.org/gitlab"), HOSTS },
  { "https://gitlab.example.com:8443/g/r/-/jobs/1", W("job", "g/r", { id = 1 }, "gitlab.example.com", "https://gitlab.example.com:8443") },
}

for _, c in ipairs(ok_cases) do
  T["parses " .. c[1]] = function()
    local t, err = context.parse_web_url(c[1], c[3] and { hosts = c[3] } or nil)
    eq(err, nil)
    eq(t, c[2])
  end
end

local bad_cases = {
  "https://gitlab.com/group/repo/-/epics/1",
  "https://gitlab.com/group/repo/-/issues/abc",
  "https://gitlab.com/group/repo/-/issues/12abc",
  "https://gitlab.com/group/repo/-/issues",
  "https://gitlab.com/repo",
  "git@gitlab.com:group/repo.git",
  "ftp://gitlab.com/g/r",
}

for _, url in ipairs(bad_cases) do
  T["rejects " .. url] = function()
    local t, err = context.parse_web_url(url)
    eq(t, nil)
    eq(err.kind, "validation")
  end
end

T["parse_ref"] = function()
  eq(context.parse_ref("#12", "g/r"), { kind = "issue", project = "g/r", iid = 12 })
  eq(context.parse_ref("!3", "g/r"), { kind = "merge_request", project = "g/r", iid = 3 })
  eq(context.parse_ref("group/sub/repo#7"), { kind = "issue", project = "group/sub/repo", iid = 7 })
  eq(context.parse_ref(" group/repo!8 "), { kind = "merge_request", project = "group/repo", iid = 8 })
  for _, bad in ipairs({ "#12", "12", "#", "#x", "repo#1", "group/#1", "a b/c#1", "/g/r#1" }) do
    local r, err = context.parse_ref(bad)
    eq(r, nil)
    eq(err.kind, "validation")
  end
  eq(select(2, context.parse_ref(nil)).kind, "validation")
end

return T
