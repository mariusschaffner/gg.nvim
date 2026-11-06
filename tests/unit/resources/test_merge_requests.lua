local H = require("tests.helpers")
local fake_backend = require("gg.transport.backends.fake")
local mrs = require("gg.resources.merge_requests")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P, MP = H.TEST_HOST, "gitlab-org/cli", "my-group/my-project"

local function iids(items)
  return vim.tbl_map(function(m)
    return m.iid
  end, items)
end

T["list (project): GraphQL request shape"] = function()
  local fake = H.fake({ "graphql/merge_requests/list_project.json" })
  local page = H.await(mrs.list({ host = HOST, project = P, state = "merged", order_by = "merged_at" }, { per_page = 2 }))
  eq(iids(page.items), { 4002, 4293 })
  eq(page.items[1].project, P)
  eq(page.next_cursor:sub(1, 2), "g:")
  eq(fake:last().variables, { fullPath = P, first = 2, state = "merged", sort = "MERGED_AT_DESC" })
end

T["list_all (project): two pages, truncated"] = function()
  local fake = H.fake({ "graphql/merge_requests/list_project.json" })
  local res = H.await(mrs.list_all({ host = HOST, project = P, state = "merged", order_by = "merged_at" }, { limit = 4, per_page = 2 }))
  eq(#res.items, 4)
  eq(res.truncated, true)
  eq(#fake:requests(), 2)
end

T["list (group)"] = function()
  local fake = H.fake({ "graphql/merge_requests/list_group.json" })
  local page = H.await(mrs.list({ host = HOST, group = "gitlab-org/quality", state = "opened" }, { per_page = 1 }))
  eq(#page.items, 1)
  eq(page.items[1].project:find("gitlab-org/quality/", 1, true), 1)
  eq(fake:last().variables.includeSubgroups, true)
end

T["list (mine): default scope is the authored connection"] = function()
  local fake = H.fake({ "graphql/merge_requests/mine.json" })
  local page = H.await(mrs.list({ host = HOST, state = "merged" }))
  eq(#page.items, 2)
  eq(page.next_cursor, nil)
  eq(fake:last().variables, { first = 50, state = "merged", authored = true, assigned = false, reviewRequested = false })
  local page2 = H.await(mrs.list({ host = HOST, scope = "reviews_for_me" }))
  eq(#page2.items, 1)
end

T["list (mine): no signed-in user is an auth error"] = function()
  H.fake({ "graphql/merge_requests/mine.json" })
  local _, err = H.await(mrs.list({ host = HOST, scope = "assigned_to_me" }))
  eq(err.kind, "auth")
end

T["list (scope all): REST /merge_requests"] = function()
  local fake = H.fake({ "rest/merge_requests/list_all.json" })
  local res = H.await(mrs.list_all({ host = HOST, scope = "all", state = "merged" }, { limit = 10, per_page = 2 }))
  eq(#res.items, 2)
  eq(res.truncated, false)
  eq(fake:last().query.scope, "all")
  eq(fake:last().query.with_labels_details, "true")
end

T["list: filter mapping"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "MergeRequestsListProject" }, response = { body = { data = { project = { mergeRequests = { nodes = {}, pageInfo = { hasNextPage = false } } } } } }, ["repeat"] = true })
  H.await(mrs.list({
    host = HOST,
    project = P,
    labels = { "a" },
    milestone = "Any",
    author_username = "user-1",
    assignee_username = "None",
    reviewer_username = "user-2",
    search = "fix",
    iids = { 3 },
    source_branch = "feat",
    target_branch = "main",
    draft = false,
    order_by = "title",
    sort = "asc",
  }))
  eq(fake:last().variables, {
    fullPath = P,
    first = 50,
    labelName = { "a" },
    milestoneWildcardId = "ANY",
    authorUsername = "user-1",
    assigneeWildcardId = "NONE",
    reviewerUsername = "user-2",
    search = "fix",
    iids = { "3" },
    sourceBranches = { "feat" },
    targetBranches = { "main" },
    draft = false,
    sort = "TITLE_ASC",
  })
end

T["get and by_iids"] = function()
  local fake = H.fake({ "graphql/merge_requests/get.json" })
  local m = H.await(mrs.get({ host = HOST, project = P, iid = 4002 }))
  eq(m.iid, 4002)
  eq(m.subscribed, false)
  eq(fake:last().variables, { fullPath = P, iid = "4002" })

  local nodes = fake_backend.read(H.path("tests/fixtures/graphql/merge_requests/list_project.json"))[1].response.body.data.project.mergeRequests.nodes
  fake:add({
    request = { operation = "MergeRequestsListProject", variables = { iids = { "4002", "4293" }, state = "all" } },
    response = { body = { data = { project = { mergeRequests = { nodes = nodes, pageInfo = { hasNextPage = false } } } } } },
  })
  eq(iids(H.await(mrs.by_iids({ host = HOST, project = P, iids = { 4002, 4293 } }))), { 4002, 4293 })
end

T["related_to_issue: REST, default per_page 20"] = function()
  local fake = H.fake({ "rest/merge_requests/related.json" })
  local page = H.await(mrs.related_to_issue({ host = HOST, project = P, iid = 8568 }))
  eq(#page.items >= 1, true)
  eq(page.items[1].iid, 4002)
  eq(page.next_cursor, nil)
  eq(fake:last().query, { page = "1", per_page = "20" })
end

T["create: REST, then the draft mutation when asked"] = function()
  local fake = H.fake({ "rest/merge_requests/write.json", "graphql/merge_requests/set_draft.json" })
  local m = H.await(mrs.create({
    host = HOST,
    project = MP,
    source_branch = "feature",
    target_branch = "main",
    title = "Add feature",
    reviewer_ids = { 2 },
    labels = { "bug", "ui" },
    draft = true,
  }))
  eq(m.draft, true)
  eq(m.title:sub(1, 7), "Draft: ")
  eq(fake:requests()[1].method, "POST")
  eq(fake:requests()[2].operation, "MergeRequestSetDraft")
  eq(fake:requests()[2].variables, { projectPath = MP, iid = "12", draft = true })
end

T["update: clearing reviewers, milestone and labels"] = function()
  local fake = H.fake({ "rest/merge_requests/write.json" })
  local m = H.await(mrs.update({ host = HOST, project = MP, iid = 12, title = "Better title", reviewer_ids = {}, milestone_id = false, labels = "" }))
  eq(m.title, "Better title")
  eq(m.reviewers, {})
  eq(fake:last().json, { title = "Better title", reviewer_ids = { 0 }, milestone_id = 0, labels = "" })
end

T["update: draft only uses the mutation, payload errors are validation"] = function()
  local fake = H.fake({ "graphql/merge_requests/set_draft.json" })
  local m = H.await(mrs.update({ host = HOST, project = MP, iid = 12, draft = true }))
  eq(m.draft, true)
  eq(#fake:requests(), 1)
  local _, err = H.await(mrs.update({ host = HOST, project = MP, iid = 13, draft = true }))
  eq(err.kind, "validation")
  eq(err.message, "Cannot set draft on a merged merge request")
end

T["merge: success and documented errors"] = function()
  local fake = H.fake({ "rest/merge_requests/write.json" })
  local m = H.await(mrs.merge({ host = HOST, project = MP, iid = 12, squash = true, should_remove_source_branch = true, sha = "abc123" }))
  eq(m.state, "merged")
  eq(fake:last().path, "/api/v4/projects/my-group%2Fmy-project/merge_requests/12/merge")
  local _, e405 = H.await(mrs.merge({ host = HOST, project = MP, iid = 13 }))
  eq({ e405.kind, e405.status }, { "validation", 405 })
  local _, e409 = H.await(mrs.merge({ host = HOST, project = MP, iid = 14 }))
  eq({ e409.kind, e409.message }, { "validation", "409 Conflict: SHA does not match HEAD of source branch: abc123" })
  local _, e422 = H.await(mrs.merge({ host = HOST, project = MP, iid = 15 }))
  eq(e422.message, "422 Unprocessable Entity: Branch cannot be merged")
end

T["errors and validation"] = function()
  local fake = H.fake({ "rest/merge_requests/write.json" })
  fake:add({ request = { operation = "MergeRequestGet" }, response = { body = { data = { project = { mergeRequest = vim.NIL } } } } })
  fake:add({ request = { operation = "MergeRequestsListProject" }, response = { status = 403, body = { message = "403 Forbidden" } } })
  eq(select(2, H.await(mrs.get({ host = HOST, project = P, iid = 1 }))).kind, "not_found")
  eq(select(2, H.await(mrs.list({ host = HOST, project = "secret/p" }))).kind, "forbidden")
  eq(select(2, H.await(mrs.update({ host = HOST, project = MP, iid = 999, title = "x" }))).kind, "not_found")
  local cases = {
    { mrs.list, { host = HOST, scope = "assigned_to_me", author_username = "x" } },
    { mrs.list, { host = HOST, scope = "all", order_by = "merged_at" } },
    { mrs.list, { host = HOST, project = P, scope = "all" } },
    { mrs.list, { host = HOST, state = "open" } },
    { mrs.update, { host = HOST, project = MP, iid = 1 } },
    { mrs.create, { host = HOST, project = MP, title = "x" } },
    { mrs.merge, { host = HOST, project = MP } },
  }
  for i, c in ipairs(cases) do
    local _, err = H.await(c[1](c[2]))
    if not err or err.kind ~= "validation" then
      error(("case %d: expected validation, got %s"):format(i, vim.inspect(err)))
    end
  end
end

return T
