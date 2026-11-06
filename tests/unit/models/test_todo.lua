local todo = require("gg.models.todo")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["from_rest and from_graphql handle missing parts"] = function()
  local t = todo.from_rest({ id = 1, action_name = "marked", target_type = "Issue", target = vim.NIL, project = vim.NIL, state = "pending" })
  eq({ t.id, t.action, t.target_type, t.project, t.target }, { 1, "marked", "issue", nil, {} })
  local g = todo.from_graphql({ id = "gid://gitlab/Todo/5", action = "assigned", targetType = "EPIC", target = { name = "Roadmap" }, state = "done", group = { fullPath = "g" } })
  eq({ g.id, g.target_type, g.target.title, g.group }, { 5, "epic", "Roadmap", "g" })
  eq(todo.from_rest(nil), nil)
  eq(todo.from_graphql(vim.NIL), nil)
end

return T
