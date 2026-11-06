local H = require("tests.helpers")
local fake = require("gg.transport.backends.fake")
local gid = require("gg.models.gid")
local issue = require("gg.models.issue")
local util = require("gg.models.util")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function gql_nodes()
  local fx = fake.read(H.path("tests/fixtures/graphql/issues/list_project.json"))
  local out = {}
  for _, page in ipairs(fx) do
    vim.list_extend(out, page.response.body.data.project.issues.nodes)
  end
  return out
end

local function find(nodes, iid)
  for _, n in ipairs(nodes) do
    if n.iid == iid then
      return n
    end
  end
end

T["gid helpers"] = function()
  eq(gid.tail("gid://gitlab/Issue/207568333"), 207568333)
  eq(gid.tail("gid://gitlab/Discussion/abc123"), "abc123")
  eq(gid.tail(5), 5)
  eq(gid.tail(nil), nil)
  eq(gid.type("gid://gitlab/ProjectLabel/1"), "ProjectLabel")
  eq(gid.build("Project", 42), "gid://gitlab/Project/42")
end

T["util helpers"] = function()
  eq(util.date("2026-11-13T00:00:00Z"), "2026-11-13")
  eq(util.date(vim.NIL), nil)
  eq(util.web_url("/groups/g/-/milestones/1", "https://h.example.com"), "https://h.example.com/groups/g/-/milestones/1")
  eq(util.web_url("https://x.example.com/a", "https://h"), "https://x.example.com/a")
  eq(util.project_of_reference("group/sub/repo#12"), "group/sub/repo")
  eq(util.project_of_reference("g/r!3"), "g/r")
  eq(util.project_of_reference("#12"), "")
end

T["from_graphql: every field of a real gitlab.com issue"] = function()
  local n = find(gql_nodes(), "8666")
  local i = issue.from_graphql(n, { origin = "https://gitlab.com" })
  eq(i.id, 207568333)
  eq(i.iid, 8666)
  eq(i.project, "gitlab-org/cli")
  eq(i.title:sub(1, 30), "mr create: without --head, the")
  eq(i.description, nil)
  eq(i.state, "opened")
  eq(i.type, "issue")
  eq(i.confidential, false)
  eq(i.author, {
    id = 6861791,
    username = "user-1",
    name = "Test User 1",
    avatar_url = "https://gitlab.example.com/uploads/avatar.png",
    web_url = "https://gitlab.example.com/user-1",
    state = "active",
  })
  eq(i.assignees, {})
  eq(#i.labels, 8)
  eq(i.labels[1], {
    id = 17435956,
    name = "automation:ml",
    color = "#ffecdb",
    text_color = "#1F1E24",
    description = "Issues triaged using AI- https://gitlab.com/gitlab-org/quality/triage-ops/-/blob/master/policies/stages/report/untriaged-issues.yml",
  })
  eq(i.milestone, nil)
  eq(i.weight, nil)
  eq(i.due_date, nil)
  eq(i.web_url, "https://gitlab.com/gitlab-org/cli/-/work_items/8666")
  eq(i.references, { short = "#8666", full = "gitlab-org/cli#8666" })
  eq(i.user_notes_count, 6)
  eq(i.created_at, "2026-10-22T16:15:47Z")
  eq(i.updated_at, "2026-11-06T12:26:26Z")
  eq(i.closed_at, nil)
  eq(i.subscribed, nil)
  eq(i.truncated, nil)
end

T["from_graphql: milestone web path joins the origin, not the base URL"] = function()
  local n = find(gql_nodes(), "8279")
  local i = issue.from_graphql(n, { origin = "https://gitlab.com" })
  eq(i.milestone, {
    id = 7324669,
    iid = 144,
    title = "19.6",
    state = "active",
    due_date = "2026-11-13",
    start_date = "2026-10-10",
    web_url = "https://gitlab.com/groups/gitlab-org/-/milestones/144",
  })
  eq(#i.assignees > 0, true)
  eq(i.assignees[1].username:match("^user%-%d+$") ~= nil, true)
end

T["from_graphql: nested truncation is reported"] = function()
  local n = vim.deepcopy(find(gql_nodes(), "8666"))
  n.labels.pageInfo.hasNextPage = true
  local i = issue.from_graphql(n)
  eq(i.truncated, { labels = true })
end

T["from_rest: docs example"] = function()
  local fx = fake.read(H.path("tests/fixtures/rest/issues/list_global.json"))
  local i = issue.from_rest(fx[1].response.body[1])
  eq(i.id, 76)
  eq(i.iid, 6)
  eq(i.project, "my-group/my-project")
  eq(i.state, "opened")
  eq(i.type, "issue")
  eq(i.description, "Ratione dolores corrupti mollitia soluta quia.")
  eq(i.labels[1], { id = 7, name = "foo", color = "#d9534f", text_color = "#FFFFFF", description = "Foo label" })
  eq(i.labels[2].description, nil)
  eq(i.milestone, {
    id = 5,
    iid = 1,
    title = "v2.0",
    state = "closed",
    due_date = "2018-09-22",
    start_date = nil,
    web_url = "https://gitlab.example.com/my-group/my-project/-/milestones/1",
  })
  eq(i.assignees[1].username, "user-1")
  eq(i.author.avatar_url, "https://gitlab.example.com/uploads/avatar.png")
  eq(i.due_date, "2016-07-22")
  eq(i.references, { short = "#6", full = "my-group/my-project#6" })
  eq(i.user_notes_count, 1)
  eq(i.closed_at, nil)
  local second = issue.from_rest(fx[2].response.body[1])
  eq({ second.type, second.confidential, second.weight, second.project }, { "incident", true, 3, "other/project" })
end

T["from_rest: label names only, single assignee fallback"] = function()
  local i = issue.from_rest({ id = 1, iid = 2, labels = { "bug", "ui" }, assignee = { id = 3, username = "user-3", name = "Test User 3" } })
  eq(i.labels, { { name = "bug" }, { name = "ui" } })
  eq(i.assignees[1].id, 3)
  eq(i.user_notes_count, 0)
end

T["nil and non-tables map to nil"] = function()
  eq(issue.from_rest(nil), nil)
  eq(issue.from_graphql(vim.NIL), nil)
end

return T
