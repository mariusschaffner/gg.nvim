local H = require("tests.helpers")
local fake_backend = require("gg.transport.backends.fake")
local milestones = require("gg.resources.milestones")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P, MP = H.TEST_HOST, "gitlab-org/cli", "my-group/my-project"

local function titles(items)
  return vim.tbl_map(function(m)
    return m.title
  end, items)
end

T["list: active, ancestors included, request shape"] = function()
  local fake = H.fake({ "graphql/milestones/list.json" })
  local page = H.await(milestones.list({ host = HOST, project = P, order_by = "due_date", sort = "asc" }, { per_page = 2 }))
  eq(titles(page.items), { "18.3", "18.4" })
  local m = page.items[1]
  eq(m.state, "active")
  eq(m.group, "gitlab-org")
  eq(m.project, nil)
  eq(m.web_url:find("https://gitlab.example.com/groups/gitlab-org/-/milestones/", 1, true), 1)
  eq(fake:last().variables, { fullPath = P, first = 2, state = "active", includeAncestors = true, sort = "DUE_DATE_ASC" })
end

T["list_all: two pages, truncated; state all sends no state"] = function()
  local fake = H.fake({ "graphql/milestones/list.json" })
  local res = H.await(milestones.list_all({ host = HOST, project = P, order_by = "due_date" }, { limit = 3, per_page = 2 }))
  eq(titles(res.items), { "18.3", "18.4", "18.5" })
  eq(res.truncated, true)
  fake:reset():add({ request = { operation = "MilestonesList" }, response = { body = { data = { project = { milestones = { nodes = {}, pageInfo = { hasNextPage = false } } } } } } })
  H.await(milestones.list({ host = HOST, project = P, state = "all", include_ancestors = false }))
  eq(fake:last().variables, { fullPath = P, first = 100, includeAncestors = false })
end

T["get: by global ID, web URL from the origin (no doubled root)"] = function()
  local fake = H.fake({ "graphql/milestones/get.json" }, { hosts = { [H.TEST_HOST] = { base_url = "https://gitlab.example.com/gitlab", token = H.TEST_TOKEN } } })
  local m = H.await(milestones.get({ host = HOST, id = 7324669 }))
  eq(m, {
    id = 7324669,
    iid = 144,
    title = "19.6",
    state = "active",
    start_date = "2026-10-10",
    due_date = "2026-11-13",
    web_url = "https://gitlab.example.com/groups/gitlab-org/-/milestones/144",
    group = "gitlab-org",
    description = "",
    expired = false,
    created_at = "2026-03-03T22:58:31Z",
    updated_at = "2026-03-03T22:58:31Z",
  })
  eq(fake:last().variables, { id = "gid://gitlab/Milestone/7324669" })
end

T["issues and merge_requests: filtered by the milestone title"] = function()
  local fake = H.fake()
  local inodes = fake_backend.read(H.path("tests/fixtures/graphql/issues/list_project.json"))[1].response.body.data.project.issues.nodes
  local mnodes = fake_backend.read(H.path("tests/fixtures/graphql/merge_requests/list_project.json"))[1].response.body.data.project.mergeRequests.nodes
  fake:add({
    request = { operation = "IssuesListProject", variables = { milestoneTitle = { "19.6" }, state = "all" } },
    response = { body = { data = { project = { issues = { nodes = inodes, pageInfo = { hasNextPage = false } } } } } },
  })
  fake:add({
    request = { operation = "MergeRequestsListProject", variables = { milestoneTitle = "19.6", state = "all" } },
    response = { body = { data = { project = { mergeRequests = { nodes = mnodes, pageInfo = { hasNextPage = false } } } } } },
  })
  local ip = H.await(milestones.issues({ host = HOST, project = P, title = "19.6" }))
  eq(#ip.items, 3)
  local mp = H.await(milestones.merge_requests_all({ host = HOST, project = P, title = "19.6" }, { limit = 10 }))
  eq(#mp.items, 2)
  eq(mp.truncated, false)
end

T["create and update (REST)"] = function()
  local fake = H.fake({ "rest/milestones/write.json" })
  local m = H.await(milestones.create({ host = HOST, project = MP, title = "v1.0", description = "First release", start_date = "2026-11-01", due_date = "2026-12-31" }))
  eq({ m.id, m.iid, m.state, m.project, m.web_url }, { 12, 3, "active", MP, "https://gitlab.example.com/my-group/my-project/-/milestones/3" })
  local u = H.await(milestones.update({ host = HOST, project = MP, id = 12, state_event = "close" }))
  eq(u.state, "closed")
  eq(fake:last().json, { state_event = "close" })
end

T["errors and validation"] = function()
  local fake = H.fake({ "rest/milestones/write.json" })
  fake:add({ request = { operation = "MilestoneGet" }, response = { body = { data = { milestone = vim.NIL } } } })
  fake:add({ request = { operation = "MilestonesList" }, response = { status = 403, body = { message = "403 Forbidden" } } })
  eq(select(2, H.await(milestones.get({ host = HOST, id = 1 }))).kind, "not_found")
  eq(select(2, H.await(milestones.list({ host = HOST, project = "secret/p" }))).kind, "forbidden")
  eq(select(2, H.await(milestones.update({ host = HOST, project = MP, id = 999, title = "x" }))).kind, "not_found")
  local _, dup = H.await(milestones.create({ host = HOST, project = MP, title = "dup" }))
  eq({ dup.kind, dup.message }, { "validation", "400 Bad Request: Milestone title already exists in project" })
  eq(select(2, H.await(milestones.update({ host = HOST, project = MP, id = 12 }))).kind, "validation")
  eq(select(2, H.await(milestones.update({ host = HOST, project = MP, id = 12, state_event = "reopen" }))).kind, "validation")
  eq(select(2, H.await(milestones.issues({ host = HOST, project = MP }))).kind, "validation")
end

return T
