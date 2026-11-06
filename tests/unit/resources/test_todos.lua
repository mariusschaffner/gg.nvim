local H = require("tests.helpers")
local todo = require("gg.models.todo")
local todos = require("gg.resources.todos")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST = H.TEST_HOST

T["list: pending by default, mapped to-dos"] = function()
  local fake = H.fake({ "graphql/todos/list.json" })
  local page = H.await(todos.list({ host = HOST }, { per_page = 2 }))
  eq(#page.items, 2)
  eq(page.items[1], {
    id = 102,
    action = "review_requested",
    target_type = "merge_request",
    target = { iid = 12, title = "Add pagination to the issue list", web_url = "https://gitlab.example.com/my-group/my-project/-/merge_requests/12" },
    target_url = "https://gitlab.example.com/my-group/my-project/-/merge_requests/12",
    body = "Add pagination to the issue list",
    state = "pending",
    project = "my-group/my-project",
    author = { id = 2, username = "user-2", name = "Test User 2", web_url = "https://gitlab.example.com/user-2", state = "active" },
    created_at = "2026-11-05T10:00:00Z",
  })
  eq(fake:last().variables, { first = 2, state = { "pending" } })
end

T["list_all: two pages; a commit target has no iid"] = function()
  local fake = H.fake({ "graphql/todos/list.json" })
  local res = H.await(todos.list_all({ host = HOST }, { limit = 10, per_page = 2 }))
  eq(#res.items, 3)
  eq(res.truncated, false)
  eq(res.items[3].target_type, "commit")
  eq(res.items[3].target.iid, nil)
  eq(res.items[3].target.title, "33e2ee85")
  eq(#fake:requests(), 2)
end

T["list: filters; no signed-in user is auth"] = function()
  local fake = H.fake({ "graphql/todos/list.json" })
  local _, err = H.await(todos.list({ host = HOST, state = "done" }))
  eq(err.kind, "auth")
  fake:reset():add({ request = { operation = "TodosList" }, response = { body = { data = { currentUser = { todos = { nodes = {}, pageInfo = { hasNextPage = false } } } } } } })
  H.await(todos.list({ host = HOST, state = "all", type = "merge_request", action = "assigned", sort = "updated_desc" }))
  eq(fake:last().variables, { first = 50, type = { "MERGEREQUEST" }, action = { "assigned" }, sort = "UPDATED_DESC" })
end

T["mark_done"] = function()
  local fake = H.fake({ "rest/todos/mark_done.json" })
  local t = H.await(todos.mark_done({ host = HOST, id = 102 }))
  eq({ t.id, t.state, t.target_type, t.project, t.target.iid }, { 102, "done", "merge_request", "my-group/my-project", 12 })
  eq(fake:last().method, "POST")
  eq(select(2, H.await(todos.mark_done({ host = HOST, id = 999 }))).kind, "not_found")
  eq(select(2, H.await(todos.list({ host = HOST, type = "snippet" }))).kind, "validation")
end

T["target_type normalization"] = function()
  eq(todo.target_type("MERGEREQUEST"), "merge_request")
  eq(todo.target_type("MergeRequest"), "merge_request")
  eq(todo.target_type("DesignManagement::Design"), "design")
  eq(todo.target_type("WORKITEM"), "work_item")
  eq(todo.target_type("KEY"), "key")
end

return T
