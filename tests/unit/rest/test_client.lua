local H = require("tests.helpers")
local config = require("gg.config")
local rest = require("gg.rest.client")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

T["encode"] = function()
  eq(rest.encode("group/sub/repo"), "group%2Fsub%2Frepo")
  eq(rest.encode("a b+c&d=e"), "a%20b%2Bc%26d%3De")
  eq(rest.encode("ünï"), "%C3%BCn%C3%AF")
  eq(rest.encode("keep-_.~AZaz09"), "keep-_.~AZaz09")
end

T["project: paths are encoded, IDs pass through"] = function()
  eq(rest.project("group/sub/repo"), "group%2Fsub%2Frepo")
  eq(rest.project("/group/repo/"), "group%2Frepo")
  eq(rest.project("my group/my.repo"), nil)
  eq(rest.project(42), "42")
  eq(rest.project("42"), "42")
  for _, bad in ipairs({ "repo", "", 0, -1, 1.5, "a//b", {}, true }) do
    local seg, err = rest.project(bad)
    eq(seg, nil)
    eq(err.kind, "validation")
  end
end

T["query: keys sorted and encoded, arrays as key[]"] = function()
  eq(rest.query({ state = "opened", labels = "bug,ui x", per_page = 20, confidential = false }), "confidential=false&labels=bug%2Cui%20x&per_page=20&state=opened")
  eq(rest.query({ iids = { 1, 2 } }), "iids%5B%5D=1&iids%5B%5D=2")
  eq(rest.query({ a = vim.NIL, b = nil, ["weird key"] = "v" }), "weird%20key=v")
  eq(rest.query(nil), "")
end

T["url: base URL with a relative root"] = function()
  config.setup({ hosts = { ["h.example.com"] = { base_url = "https://h.example.com/gitlab/" } }, log = { level = "off" } })
  eq(rest.url("h.example.com", "/projects/1", { a = 1 }), "https://h.example.com/gitlab/api/v4/projects/1?a=1")
  eq(select(2, rest.url("h.example.com", "user")).kind, "validation")
  eq(select(2, rest.url("not-configured.example.com", "/user")).kind, "validation")
end

T["request: JSON body sets Content-Type, GET does not"] = function()
  local fake = H.fake()
  fake:add({ request = { method = "POST", path = "/api/v4/projects/g%2Fr/issues", body_contains = { title = "T" } }, response = { status = 201, body = { iid = 1 } } })
  fake:add({ request = { path = "/api/v4/user" }, response = { body = { id = 7 } } })
  local res = H.await(rest.request(H.TEST_HOST, "POST", "/projects/" .. rest.project("g/r") .. "/issues", { body = { title = "T" } }))
  eq(res.status, 201)
  eq(res.data, { iid = 1 })
  eq(fake:requests()[1].headers["Content-Type"], "application/json")
  eq(fake:requests()[1].headers.Accept, "application/json")
  local data = H.await(rest.get(H.TEST_HOST, "/user"))
  eq(data, { id = 7 })
  eq(fake:requests()[2].headers["Content-Type"], nil)
end

T["request: 204 resolves with nil data"] = function()
  local fake = H.fake()
  fake:add({ request = { method = "DELETE", path = "/api/v4/projects/1/issues/2" }, response = { status = 204 } })
  local res = H.await(rest.request(H.TEST_HOST, "DELETE", "/projects/1/issues/2"))
  eq(res.status, 204)
  eq(res.data, nil)
  eq(fake:last().method, "DELETE")
end

T["request: errors are mapped"] = function()
  local fake = H.fake()
  fake:add({ request = { path = "/api/v4/projects/1" }, response = { status = 404, body = { message = "404 Project Not Found" } } })
  local _, err = H.await(rest.get(H.TEST_HOST, "/projects/1"))
  eq(err.kind, "not_found")
  eq(err.message, "404 Project Not Found")
end

T["page: offset pages with per_page and cursor"] = function()
  local fake = H.fake({ "transport/offset_pages.json" })
  local p1 = H.await(rest.page(H.TEST_HOST, "/projects/1/labels", { per_page = 2 }))
  eq(#p1.items, 2)
  eq(p1.next_cursor, "o:2")
  local p2 = H.await(rest.page(H.TEST_HOST, "/projects/1/labels", { per_page = 2, cursor = p1.next_cursor }))
  eq(p2.items[1].id, 3)
  eq(fake:requests()[2].query, { page = "2", per_page = "2" })
end

T["page: keyset follows the Link URL"] = function()
  local fake = H.fake({ "transport/keyset_pages.json" })
  local p1 = H.await(rest.page(H.TEST_HOST, "/projects", { pagination = "keyset", per_page = 2, query = { order_by = "id", sort = "asc" } }))
  eq(p1.next_cursor:sub(1, 2), "k:")
  local p2 = H.await(rest.page(H.TEST_HOST, "/projects", { pagination = "keyset", per_page = 2, cursor = p1.next_cursor }))
  eq(p2.items[1].id, 3)
  eq(fake:requests()[2].query.id_after, "2")
end

T["page: a non-list body is an error"] = function()
  local fake = H.fake()
  fake:add({ request = { path = "/api/v4/x" }, response = { body = { not_a = "list" } } })
  local _, err = H.await(rest.page(H.TEST_HOST, "/x"))
  eq(err.kind, "unknown")
end

T["page: bad cursors are validation errors"] = function()
  H.fake()
  local _, err = H.await(rest.page(H.TEST_HOST, "/x", { cursor = "nope" }))
  eq(err.kind, "validation")
  local _, err2 = H.await(rest.page(H.TEST_HOST, "/x", { cursor = "g:abc" }))
  eq(err2.kind, "validation")
end

return T
