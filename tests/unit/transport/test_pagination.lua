local H = require("tests.helpers")
local http = require("gg.transport.http")
local pagination = require("gg.transport.pagination")
local task = require("gg.core.task")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local BASE = "https://gitlab.example.com"

local function ids(items)
  local out = {}
  for i, it in ipairs(items) do
    out[i] = tonumber(it.id)
  end
  return out
end

-- page fetchers built directly on transport (the clients come in item 4)
local function offset_fetch(_, o)
  return task.run(function()
    local c, cerr = pagination.rest_cursor(o.cursor, http.origin(BASE), http.origin)
    if not c then
      return nil, cerr
    end
    local res, err = http.request({
      host = H.TEST_HOST,
      url = ("%s/api/v4/projects/1/labels?page=%d&per_page=%d"):format(BASE, c.page, o.per_page),
      decode = "json",
    }):await()
    if err then
      return nil, err
    end
    return { items = res.data, next_cursor = pagination.rest_next(res.headers, "offset") }
  end)
end

local function keyset_fetch(_, o)
  return task.run(function()
    local c, cerr = pagination.rest_cursor(o.cursor, http.origin(BASE), http.origin)
    if not c then
      return nil, cerr
    end
    local url = c.url or (BASE .. "/api/v4/projects?pagination=keyset&order_by=id&sort=asc&per_page=" .. o.per_page)
    local res, err = http.request({ host = H.TEST_HOST, url = url, decode = "json" }):await()
    if err then
      return nil, err
    end
    return { items = res.data, next_cursor = pagination.rest_next(res.headers, "keyset") }
  end)
end

local function graphql_fetch(_, o)
  return task.run(function()
    local after, aerr = pagination.graphql_after(o.cursor)
    if aerr then
      return nil, aerr
    end
    local res, err = http.request({
      host = H.TEST_HOST,
      method = "POST",
      url = BASE .. "/api/graphql",
      body = vim.json.encode({ query = "query Things {}", operationName = "Things", variables = { first = o.per_page, after = after } }),
      decode = "json",
    }):await()
    if err then
      return nil, err
    end
    local conn = res.data.data.project.things
    return { items = conn.nodes, next_cursor = pagination.graphql_next(conn.pageInfo) }
  end)
end

T["parse_link"] = function()
  local links = pagination.parse_link('<https://h/a?page=2>; rel="next", <https://h/a?page=1>; rel="first", <https://h/a?page=9>; rel="last"')
  eq(links, { next = "https://h/a?page=2", first = "https://h/a?page=1", last = "https://h/a?page=9" })
  eq(pagination.parse_link(nil), {})
  eq(pagination.parse_link("<https://h/x>; rel=next"), { next = "https://h/x" })
end

T["cursors are opaque strings that round-trip"] = function()
  eq({ pagination.decode(pagination.encode("offset", 3)) }, { "offset", "3" })
  eq({ pagination.decode(pagination.encode("graphql", "abc:def")) }, { "graphql", "abc:def" })
  local kind, err = pagination.decode("garbage")
  eq(kind, nil)
  eq(err.kind, "validation")
  eq(select(2, pagination.decode(42)).kind, "validation")
end

T["rest_next: x-next-page, Link fallback, empty means last"] = function()
  eq(pagination.rest_next({ ["x-next-page"] = "2" }, "offset"), "o:2")
  eq(pagination.rest_next({ ["x-next-page"] = "" }, "offset"), nil)
  eq(pagination.rest_next({ link = '<https://h/x?page=4>; rel="next"' }, "offset"), "o:4")
  eq(pagination.rest_next({ link = '<https://h/x?id_after=9>; rel="next"' }, "keyset"), "k:https://h/x?id_after=9")
  eq(pagination.rest_next({}, "keyset"), nil)
end

T["per_page is clamped to 1..100"] = function()
  eq(pagination.per_page(nil), 100)
  eq(pagination.per_page(nil, 20), 20)
  eq(pagination.per_page(500), 100)
  eq(pagination.per_page(0), 1)
end

T["offset: three pages"] = function()
  local fake = H.fake({ "transport/offset_pages.json" })
  local res = H.await(pagination.collect(offset_fetch, {}, { limit = 100, per_page = 2 }))
  eq(ids(res.items), { 1, 2, 3, 4, 5 })
  eq(res.truncated, false)
  eq(#fake:requests(), 3)
end

T["keyset: follows Link rel=next as given"] = function()
  local fake = H.fake({ "transport/keyset_pages.json" })
  local res = H.await(pagination.collect(keyset_fetch, {}, { limit = 10, per_page = 2 }))
  eq(ids(res.items), { 1, 2, 3, 4, 5 })
  eq(fake:requests()[2].query.id_after, "2")
end

T["GraphQL: three cursor pages"] = function()
  local fake = H.fake({ "transport/graphql_pages.json" })
  local pages = {}
  local res = H.await(pagination.collect(graphql_fetch, {}, { limit = 50, per_page = 2, on_page = function(items)
    table.insert(pages, #items)
  end }))
  eq(ids(res.items), { 1, 2, 3, 4, 5 })
  eq(pages, { 2, 2, 1 })
  eq(fake:requests()[3].variables.after, "c4")
end

T["truncation at the limit, without an extra request"] = function()
  local fake = H.fake({ "transport/offset_pages.json" })
  local res = H.await(pagination.collect(offset_fetch, {}, { limit = 3, per_page = 2 }))
  eq(ids(res.items), { 1, 2, 3 })
  eq(res.truncated, true)
  eq(#fake:requests(), 2)
end

T["a limit equal to the total is not truncated"] = function()
  H.fake({ "transport/graphql_pages.json" })
  local res = H.await(pagination.collect(graphql_fetch, {}, { limit = 5, per_page = 2 }))
  eq(#res.items, 5)
  eq(res.truncated, false)
end

T["the limit is required"] = function()
  for _, bad in ipairs({ {}, { limit = 0 }, { limit = -1 }, { limit = 1.5 }, { limit = "10" } }) do
    local _, err = H.await(pagination.collect(offset_fetch, {}, bad))
    eq(err.kind, "validation")
    eq(err.details.key, "limit")
  end
end

T["a next link to another origin is refused"] = function()
  local c, err = pagination.rest_cursor("k:https://evil.example.org/api/v4/projects?id_after=2", http.origin(BASE), http.origin)
  eq(c, nil)
  eq(err.kind, "validation")
  local ok = pagination.rest_cursor("k:https://gitlab.example.com/api/v4/projects?id_after=2", http.origin(BASE), http.origin)
  eq(ok.url, "https://gitlab.example.com/api/v4/projects?id_after=2")
end

T["a cursor that does not advance is an error"] = function()
  local fetch = function()
    return task.resolved({ items = { { id = 1 } }, next_cursor = "o:2" })
  end
  local _, err = H.await(pagination.collect(fetch, {}, { limit = 10 }))
  eq(err.kind, "unknown")
end

T["errors from a page are returned"] = function()
  local fetch = function()
    return task.failed(require("gg.core.errors").new("forbidden", "no"))
  end
  local _, err = H.await(pagination.collect(fetch, {}, { limit = 10 }))
  eq(err.kind, "forbidden")
end

return T
