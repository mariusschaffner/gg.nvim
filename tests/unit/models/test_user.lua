local user = require("gg.models.user")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["from_rest"] = function()
  eq(user.from_rest({ id = 3, username = "user-3", name = "Test User 3", state = "active", avatar_url = vim.NIL, web_url = "https://gitlab.example.com/user-3" }), {
    id = 3,
    username = "user-3",
    name = "Test User 3",
    state = "active",
    web_url = "https://gitlab.example.com/user-3",
  })
end

T["from_graphql: GID tail, relative avatar made absolute"] = function()
  local u = user.from_graphql({ id = "gid://gitlab/User/9", username = "user-9", name = "Test User 9", avatarUrl = "/uploads/a.png", webUrl = "https://gitlab.example.com/user-9", state = "blocked" }, { origin = "https://gitlab.example.com" })
  eq(u.id, 9)
  eq(u.avatar_url, "https://gitlab.example.com/uploads/a.png")
  eq(u.state, "blocked")
end

T["nil in, nil out"] = function()
  eq(user.from_rest(nil), nil)
  eq(user.from_graphql(vim.NIL), nil)
end

return T
