local H = require("tests.helpers")
local users = require("gg.resources.users")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P = H.TEST_HOST, "gitlab-org/cli"

T["current: the token's user, avatar made absolute"] = function()
  local fake = H.fake({ "graphql/users/current.json" })
  local u = H.await(users.current({ host = HOST }))
  eq(u, {
    id = 1,
    username = "user-1",
    name = "Test User 1",
    avatar_url = "https://gitlab.example.com/uploads/-/system/user/avatar/1/avatar.png",
    web_url = "https://gitlab.example.com/user-1",
    state = "active",
  })
  eq(fake:last().operation, "UserCurrent")
end

T["current: no signed-in user is an auth error"] = function()
  local fake = H.fake({ "graphql/users/current.json" })
  H.await(users.current({ host = HOST }))
  local _, err = H.await(users.current({ host = HOST }))
  eq(err.kind, "auth")
  eq(#fake:requests(), 2)
end

T["project_members: request shape, access level, relations"] = function()
  local fake = H.fake({ "graphql/users/members.json" })
  local page = H.await(users.project_members({ host = HOST, project = P }, { per_page = 2 }))
  eq(#page.items, 1)
  eq(page.items[1].username, "user-1")
  eq(page.items[1].access_level, 30)
  eq(page.items[1].member_id, 177521496)
  eq(page.next_cursor:sub(1, 2), "g:")
  eq(fake:last().variables, { fullPath = P, first = 2, relations = users.RELATIONS })
end

T["project_members_all: members without a visible user are skipped"] = function()
  local fake = H.fake({ "graphql/users/members.json" })
  local res = H.await(users.project_members_all({ host = HOST, project = P }, { limit = 2, per_page = 2 }))
  eq(#res.items, 2)
  eq(res.truncated, true)
  eq(#fake:requests(), 2)
end

T["project_members: search and errors"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "ProjectMembersList", variables = { search = "ann" } }, response = { body = { data = { project = { projectMembers = { nodes = {}, pageInfo = { hasNextPage = false } } } } } } })
  fake:add({ request = { operation = "ProjectMembersList", variables = { fullPath = "nope/x" } }, response = { body = { data = { project = vim.NIL } } } })
  fake:add({ request = { operation = "UserCurrent" }, response = { status = 401, body = { message = "401 Unauthorized" } } })
  local page = H.await(users.project_members({ host = HOST, project = P, search = "ann" }))
  eq(page.items, {})
  eq(fake:last().variables.first, 100)
  eq(select(2, H.await(users.project_members({ host = HOST, project = "nope/x" }))).kind, "not_found")
  eq(select(2, H.await(users.current({ host = HOST }))).kind, "auth")
  eq(select(2, H.await(users.project_members({ host = HOST }))).kind, "validation")
end

return T
