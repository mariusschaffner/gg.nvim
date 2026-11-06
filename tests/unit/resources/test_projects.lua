local H = require("tests.helpers")
local projects = require("gg.resources.projects")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST = H.TEST_HOST

T["search: most recently active first, request shape"] = function()
  local fake = H.fake({ "graphql/projects/search.json" })
  local page = H.await(projects.search({ host = HOST, query = "gitlab-org/cli" }, { per_page = 2 }))
  eq(#page.items, 2)
  local p = page.items[1]
  eq(p.full_path, "user-1/ecoscan-16573099-deletion_scheduled-88611480")
  eq(type(p.id), "number")
  eq(p.visibility, "public")
  eq(page.next_cursor:sub(1, 2), "g:")
  eq(fake:last().variables, { search = "gitlab-org/cli", sort = "latest_activity_desc", first = 2 })
end

T["search_all: two pages, truncated; default per_page 20"] = function()
  local fake = H.fake({ "graphql/projects/search.json" })
  local res = H.await(projects.search_all({ host = HOST, query = "gitlab-org/cli" }, { limit = 4, per_page = 2 }))
  eq(#res.items, 4)
  eq(res.truncated, true)
  fake:reset():add({ request = { operation = "ProjectsSearch" }, response = { body = { data = { projects = { nodes = {}, pageInfo = { hasNextPage = false } } } } } })
  H.await(projects.search({ host = HOST, query = "x", membership = true }))
  eq(fake:last().variables, { search = "x", membership = true, sort = "latest_activity_desc", first = 20 })
end

T["get: by path, and by numeric ID"] = function()
  local fake = H.fake({ "graphql/projects/get.json" })
  local p = H.await(projects.get({ host = HOST, project = "gitlab-org/cli" }))
  eq(p, {
    id = 34675721,
    name = "cli",
    path = "cli",
    full_path = "gitlab-org/cli",
    description = "A GitLab CLI tool bringing GitLab to your command line",
    default_branch = "main",
    visibility = "public",
    web_url = "https://gitlab.com/gitlab-org/cli",
    last_activity_at = "2026-11-06T18:44:21Z",
    archived = false,
  })
  fake:reset():load("graphql/projects/get.json"):add({
    request = { operation = "ProjectPath", variables = { ids = { "gid://gitlab/Project/34675721" } } },
    response = { body = { data = { projects = { nodes = { { id = "gid://gitlab/Project/34675721", fullPath = "gitlab-org/cli" } } } } } },
  })
  eq(H.await(projects.get({ host = HOST, project = 34675721 })).full_path, "gitlab-org/cli")
end

T["errors"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "ProjectGet" }, response = { body = { data = { project = vim.NIL } } } })
  fake:add({ request = { operation = "ProjectsSearch" }, response = { status = 429, headers = { ["Retry-After"] = "120" }, body = "Retry later" } })
  eq(select(2, H.await(projects.get({ host = HOST, project = "nope/x" }))).kind, "not_found")
  eq(select(2, H.await(projects.search({ host = HOST, query = "x" }))).kind, "rate_limited")
  eq(select(2, H.await(projects.search({ host = HOST }))).kind, "validation")
end

return T
