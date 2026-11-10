local H = require("tests.helpers")
local tags = require("gg.resources.tags")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P = H.TEST_HOST, "my-group/my-project"

T["list: one page, mapped tags"] = function()
  local fake = H.fake({ "rest/tags/list.json" })
  local page = H.await(tags.list({ host = HOST, project = P, search = "^v1" }, { per_page = 2 }))
  eq(page.next_cursor, "o:2")
  eq(page.items[1], {
    name = "v1.2.0",
    commit_sha = "2695effb5807a22ff3d138d593fd856244e155e7",
    commit_title = "Initial commit",
    committed_date = "2012-05-28T04:42:42-07:00",
    protected = true,
  })
  eq({ page.items[2].name, page.items[2].message, page.items[2].protected }, { "v1.1.0", "Version 1.1.0", false })
  eq(fake:last().path, "/api/v4/projects/my-group%2Fmy-project/repository/tags")
end

T["list_all: across pages"] = function()
  local fake = H.fake({ "rest/tags/list.json" })
  local res = H.await(tags.list_all({ host = HOST, project = P, search = "^v1" }, { limit = 10, per_page = 2 }))
  eq(vim.tbl_map(function(t)
    return t.name
  end, res.items), { "v1.2.0", "v1.1.0", "v1.0.0" })
  eq(res.truncated, false)
  eq(#fake:requests(), 2)
end

T["list_all: truncated at the limit"] = function()
  H.fake({ "rest/tags/list.json" })
  local res = H.await(tags.list_all({ host = HOST, project = P, search = "^v1" }, { limit = 2, per_page = 2 }))
  eq({ #res.items, res.truncated }, { 2, true })
end

T["list: order and sort are passed on"] = function()
  local fake = H.fake()
  fake:add({ request = { method = "GET", path = "/api/v4/projects/my-group%2Fmy-project/repository/tags" }, response = { body = {} } })
  local page = H.await(tags.list({ host = HOST, project = P, order_by = "name", sort = "asc" }))
  eq(page.items, {})
  eq(fake:last().query, { page = "1", per_page = "100", order_by = "name", sort = "asc" })
end

T["errors"] = function()
  H.fake({ "rest/tags/list.json" })
  eq(select(2, H.await(tags.list({ host = HOST, project = "nope/missing" }))).kind, "not_found")
  eq(select(2, H.await(tags.list({ host = HOST, project = P, order_by = "size" }))).kind, "validation")
  eq(select(2, H.await(tags.list_all({ host = HOST, project = P }))).kind, "validation")
end

return T
