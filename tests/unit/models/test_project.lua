local project = require("gg.models.project")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["from_graphql: empty repository has no default branch"] = function()
  local p = project.from_graphql({ id = "gid://gitlab/Project/1", name = "r", path = "r", fullPath = "g/r", repository = vim.NIL })
  eq({ p.id, p.full_path, p.default_branch }, { 1, "g/r", nil })
  eq(project.from_graphql(nil), nil)
end

return T
