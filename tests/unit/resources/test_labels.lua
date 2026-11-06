local H = require("tests.helpers")
local labels = require("gg.resources.labels")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P = H.TEST_HOST, "gitlab-org/cli"

T["list: request shape and mapped labels"] = function()
  local fake = H.fake({ "graphql/labels/list.json" })
  local page = H.await(labels.list({ host = HOST, project = P, search = "bug" }, { per_page = 2 }))
  eq(#page.items, 2)
  eq(page.items[1].name, "AI bug resolution job triggered")
  eq(type(page.items[1].id), "number")
  eq(page.items[1].color:match("^#%x+$") ~= nil, true)
  eq(page.next_cursor:sub(1, 2), "g:")
  eq(fake:last().variables, { fullPath = P, first = 2, searchTerm = "bug", searchIn = { "TITLE" }, includeAncestorGroups = true })
end

T["list: ancestor groups can be excluded; default per_page is 100"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "LabelsList" }, response = { body = { data = { project = { labels = { nodes = {}, pageInfo = { hasNextPage = false } } } } } } })
  H.await(labels.list({ host = HOST, project = P, include_ancestor_groups = false }))
  eq(fake:last().variables, { fullPath = P, first = 100, searchIn = { "TITLE" }, includeAncestorGroups = false })
end

T["list_all: two pages, truncated"] = function()
  local fake = H.fake({ "graphql/labels/list.json" })
  local res = H.await(labels.list_all({ host = HOST, project = P, search = "bug" }, { limit = 4, per_page = 2 }))
  eq(#res.items, 4)
  eq(res.items[3].name, "AgenticIDE::Bug")
  eq(res.truncated, true)
  eq(#fake:requests(), 2)
end

T["errors"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "LabelsList", variables = { fullPath = "nope/missing" } }, response = { body = { data = { project = vim.NIL } } } })
  fake:add({ request = { operation = "LabelsList", variables = { fullPath = "secret/p" } }, response = { status = 403, body = { message = "403 Forbidden" } } })
  fake:add({ request = { operation = "LabelsList", variables = { fullPath = "bad/q" } }, response = { body = { errors = { { message = "Argument 'searchIn' on Field 'labels' has an invalid value" } } } } })
  eq(select(2, H.await(labels.list({ host = HOST, project = "nope/missing" }))).kind, "not_found")
  eq(select(2, H.await(labels.list({ host = HOST, project = "secret/p" }))).kind, "forbidden")
  eq(select(2, H.await(labels.list({ host = HOST, project = "bad/q" }))).kind, "graphql")
  eq(select(2, H.await(labels.list({ host = HOST, project = P, search = 3 }))).kind, "validation")
end

return T
