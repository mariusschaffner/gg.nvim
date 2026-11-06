local H = require("tests.helpers")
local fake_backend = require("gg.transport.backends.fake")
local issues = require("gg.resources.issues")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST = H.TEST_HOST
local P = "gitlab-org/cli"

local function iids(items)
  return vim.tbl_map(function(i)
    return i.iid
  end, items)
end

T["list (project): GraphQL request shape and mapped issues"] = function()
  local fake = H.fake({ "graphql/issues/list_project.json" })
  local page, err = H.await(issues.list({ host = HOST, project = P, state = "opened", order_by = "updated_at", sort = "desc" }, { per_page = 3 }))
  eq(err, nil)
  eq(#page.items, 3)
  eq(page.items[1].iid, 8666)
  eq(page.items[1].project, P)
  eq(page.next_cursor:sub(1, 2), "g:")
  local rec = fake:last()
  eq(rec.operation, "IssuesListProject")
  eq(rec.variables, { fullPath = P, first = 3, state = "opened", sort = "UPDATED_DESC" })
  eq(rec.headers["PRIVATE-TOKEN"], H.TEST_TOKEN)
end

T["list: the cursor fetches the next page"] = function()
  local fake = H.fake({ "graphql/issues/list_project.json" })
  local p1 = H.await(issues.list({ host = HOST, project = P, state = "opened", order_by = "updated_at" }, { per_page = 3 }))
  local p2 = H.await(issues.list({ host = HOST, project = P, state = "opened", order_by = "updated_at" }, { per_page = 3, cursor = p1.next_cursor }))
  eq(#p2.items, 3)
  eq(fake:last().variables.after ~= nil, true)
end

T["list_all: across pages, truncated at the limit"] = function()
  local fake = H.fake({ "graphql/issues/list_project.json" })
  local res = H.await(issues.list_all({ host = HOST, project = P, state = "opened", order_by = "updated_at" }, { limit = 6, per_page = 3 }))
  eq(#res.items, 6)
  eq(res.truncated, true)
  eq(#fake:requests(), 2)
  fake:reset():load("graphql/issues/list_project.json")
  local seen = {}
  local res2 = H.await(issues.list_all({ host = HOST, project = P, state = "opened", order_by = "updated_at" }, { limit = 4, per_page = 3, on_page = function(items)
    table.insert(seen, #items)
  end }))
  eq(#res2.items, 4)
  eq(res2.truncated, true)
  eq(seen, { 3, 1 })
end

T["list (group): includes subgroups by default, project from the reference"] = function()
  local fake = H.fake({ "graphql/issues/list_group.json" })
  local page = H.await(issues.list({ host = HOST, group = "gitlab-org/quality", state = "opened" }, { per_page = 2 }))
  eq(#page.items, 2)
  eq(page.items[1].type, "incident")
  eq(page.items[1].project, "gitlab-org/quality/engineering-productivity/master-broken-incidents")
  eq(fake:last().variables.includeSubgroups, true)
end

T["list (all projects): REST /issues with labels as CSV and label details"] = function()
  local fake = H.fake({ "rest/issues/list_global.json" })
  local res = H.await(issues.list_all({ host = HOST, scope = "assigned_to_me", state = "opened", labels = { "foo", "bar" } }, { limit = 10, per_page = 1 }))
  eq(iids(res.items), { 6, 2 })
  eq(res.truncated, false)
  eq(res.items[2].project, "other/project")
  eq(fake:requests()[1].query.labels, "foo,bar")
  eq(fake:requests()[1].query.with_labels_details, "true")
end

T["list: filter mapping to GraphQL variables"] = function()
  local fake = H.fake()
  fake:add({
    request = { operation = "IssuesListProject" },
    response = { body = { data = { project = { issues = { nodes = {}, pageInfo = { hasNextPage = false } } } } } },
    ["repeat"] = true,
  })
  H.await(issues.list({
    host = HOST,
    project = P,
    labels = "a,b",
    milestone = "None",
    assignee_username = "user-1",
    author_username = "user-2",
    search = "crash",
    iids = { 1, 2 },
    sort = "asc",
    confidential = true,
    types = { "incident" },
  }))
  eq(fake:last().variables, {
    fullPath = P,
    first = 50,
    labelName = { "a", "b" },
    milestoneWildcardId = "NONE",
    assigneeUsernames = { "user-1" },
    authorUsername = "user-2",
    search = "crash",
    iids = { "1", "2" },
    sort = "CREATED_ASC",
    confidential = true,
    types = { "INCIDENT" },
  })
  H.await(issues.list({ host = HOST, project = P, milestone = "v1", assignee_username = "Any" }))
  local v = fake:last().variables
  eq({ v.milestoneTitle, v.assigneeWildcardId }, { { "v1" }, "ANY" })
end

T["list: numeric project IDs are resolved first"] = function()
  local fake = H.fake({ "graphql/issues/list_project.json" })
  fake:add({
    request = { operation = "ProjectPath", variables = { ids = { "gid://gitlab/Project/34675721" } } },
    response = { body = { data = { projects = { nodes = { { id = "gid://gitlab/Project/34675721", fullPath = P } } } } } },
  })
  local page = H.await(issues.list({ host = HOST, project = 34675721, state = "opened", order_by = "updated_at" }, { per_page = 3 }))
  eq(#page.items, 3)
  eq(fake:requests()[1].operation, "ProjectPath")
  eq(fake:requests()[2].variables.fullPath, P)
end

T["get: description and subscription"] = function()
  local fake = H.fake({ "graphql/issues/get.json" })
  local i = H.await(issues.get({ host = HOST, project = P, iid = 1 }))
  eq(i.iid, 1)
  eq(i.state, "closed")
  eq(i.description, "")
  eq(i.subscribed, false)
  eq(i.labels[1].name, "enhancement")
  eq(fake:last().variables, { fullPath = P, iid = "1" })
end

T["by_iids"] = function()
  local fake = H.fake()
  local nodes = fake_backend.read(H.path("tests/fixtures/graphql/issues/list_project.json"))[1].response.body.data.project.issues.nodes
  fake:add({
    request = { operation = "IssuesListProject", variables = { fullPath = P, iids = { "8666", "8649" }, state = "all" } },
    response = { body = { data = { project = { issues = { nodes = { nodes[1], nodes[2] }, pageInfo = { hasNextPage = false } } } } } },
  })
  local list = H.await(issues.by_iids({ host = HOST, project = P, iids = { 8666, 8649 } }))
  eq(iids(list), { 8666, 8649 })
  eq(fake:last().variables.first, 2)
  eq(H.await(issues.by_iids({ host = HOST, project = P, iids = {} })), {})
end

T["create: REST POST with CSV labels"] = function()
  local fake = H.fake({ "rest/issues/write.json" })
  local i = H.await(issues.create({ host = HOST, project = "my-group/my-project", title = "Issues with auth", labels = { "bug", "ui" }, assignee_ids = { 1 }, milestone_id = 5 }))
  eq(i.iid, 14)
  eq(i.labels, { { name = "bug" }, { name = "ui" } })
  eq(i.subscribed, true)
  local rec = fake:last()
  eq(rec.method, "POST")
  eq(rec.headers["Content-Type"], "application/json")
end

T["update: close, clear labels, unassign, remove milestone"] = function()
  local fake = H.fake({ "rest/issues/write.json" })
  local i = H.await(issues.update({ host = HOST, project = "my-group/my-project", iid = 14, state_event = "close", labels = {}, assignee_ids = {}, milestone_id = false }))
  eq(i.state, "closed")
  eq(i.closed_at, "2016-01-08T12:44:33.959Z")
  eq(fake:last().json, { state_event = "close", labels = "", assignee_ids = { 0 }, milestone_id = 0 })
end

T["errors: not_found, forbidden, graphql, validation"] = function()
  H.fake({ "graphql/issues/errors.json", "rest/issues/write.json" })
  local _, e1 = H.await(issues.get({ host = HOST, project = P, iid = 999999 }))
  eq(e1.kind, "not_found")
  local _, e2 = H.await(issues.list({ host = HOST, project = "nope/missing" }))
  eq(e2.kind, "not_found")
  local _, e3 = H.await(issues.list({ host = HOST, group = "broken" }))
  eq(e3.kind, "graphql")
  local _, e4 = H.await(issues.list({ host = HOST, project = "secret/project" }))
  eq(e4.kind, "forbidden")
  local _, e5 = H.await(issues.create({ host = HOST, project = "my-group/secret", title = "t" }))
  eq(e5.kind, "forbidden")
  local _, e6 = H.await(issues.update({ host = HOST, project = "my-group/my-project", iid = 999, title = "t" }))
  eq(e6.kind, "not_found")
  local _, e7 = H.await(issues.create({ host = HOST, project = "my-group/my-project", title = "x" }))
  eq(e7.kind, "validation")
  eq(e7.message, "400 Bad Request: title is too short (minimum is 2 characters)")
end

T["argument validation"] = function()
  H.fake()
  local cases = {
    { issues.list, { project = P } },
    { issues.list, { host = HOST, project = P, group = "g" } },
    { issues.list, { host = HOST, project = P, scope = "all" } },
    { issues.list, { host = HOST, include_subgroups = true } },
    { issues.list, { host = HOST, order_by = "closed_at" } },
    { issues.list, { host = HOST, types = { "issue", "incident" } } },
    { issues.list, { host = HOST, project = P, types = { "bogus" } } },
    { issues.list, { host = HOST, project = P, state = "open" } },
    { issues.list, { host = HOST, project = P, colour = "red" } },
    { issues.get, { host = HOST, project = P } },
    { issues.get, { host = HOST, project = "noslash", iid = 1 } },
    { issues.create, { host = HOST, project = P } },
    { issues.create, { host = HOST, project = P, title = "t", due_date = "tomorrow" } },
    { issues.update, { host = HOST, project = P, iid = 1 } },
    { issues.update, { host = HOST, project = P, iid = 1, milestone_id = true } },
    { issues.by_iids, { host = HOST, project = P, iids = { "x" } } },
  }
  for i, c in ipairs(cases) do
    local _, err = H.await(c[1](c[2]))
    if not err or err.kind ~= "validation" then
      error(("case %d: expected a validation error, got %s"):format(i, vim.inspect(err)))
    end
  end
  local _, perr = H.await(issues.list({ host = HOST, project = P }, { per_page = 500 }))
  eq(perr.kind, "validation")
  local _, lerr = H.await(issues.list_all({ host = HOST, project = P }, {}))
  eq(lerr.details.key, "limit")
end

return T
