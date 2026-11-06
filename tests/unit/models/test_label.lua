local H = require("tests.helpers")
local fake = require("gg.transport.backends.fake")
local label = require("gg.models.label")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["from_graphql: real gitlab.com label"] = function()
  local node = fake.read(H.path("tests/fixtures/graphql/labels/list.json"))[1].response.body.data.project.labels.nodes[1]
  local l = label.from_graphql(node)
  eq(l.name, "AI bug resolution job triggered")
  eq(type(l.id), "number")
  eq(l.color, node.color)
  eq(l.text_color, node.textColor)
end

T["from_rest: object, name only, nil"] = function()
  eq(label.from_rest({ id = 7, name = "foo", color = "#d9534f", text_color = "#FFFFFF", description = vim.NIL }), {
    id = 7,
    name = "foo",
    color = "#d9534f",
    text_color = "#FFFFFF",
  })
  eq(label.from_rest("bug"), { name = "bug" })
  eq(label.from_rest(vim.NIL), nil)
  eq(label.from_graphql(nil), nil)
end

return T
