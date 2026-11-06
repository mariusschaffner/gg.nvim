local H = require("tests.helpers")
local registry = require("gg.resources.registry")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P = H.TEST_HOST, "gitlab-org/cli"

T["repositories: real gitlab.com registry"] = function()
  local fake = H.fake({ "graphql/registry/repositories.json" })
  local res = H.await(registry.repositories_all({ host = HOST, project = P }, { limit = 2, per_page = 2 }))
  eq(res.items[1], { id = 3659784, name = "", path = "gitlab-org/cli", location = "registry.gitlab.com/gitlab-org/cli", tags_count = 413, created_at = "2022-11-24T08:48:32Z" })
  eq(res.truncated, false)
  eq(fake:last().variables, { fullPath = P, first = 2 })
end

T["tags: REST keyset across pages"] = function()
  local fake = H.fake({ "rest/registry/tags.json" })
  local res = H.await(registry.tags_all({ host = HOST, project = P, repository_id = 3659784 }, { limit = 10, per_page = 2 }))
  eq(vim.tbl_map(function(t)
    return t.name
  end, res.items), { "v1.0.0", "v1.1.0", "v2.0.0" })
  eq(res.truncated, false)
  eq(fake:requests()[2].query.last, "v1.1.0")
  fake:reset():load("rest/registry/tags.json")
  local cut = H.await(registry.tags_all({ host = HOST, project = P, repository_id = 3659784 }, { limit = 2, per_page = 2 }))
  eq(cut.truncated, true)
  eq(#fake:requests(), 1)
end

T["tag details and errors"] = function()
  H.fake({ "rest/registry/tags.json" })
  local t = H.await(registry.tag({ host = HOST, project = P, repository_id = 3659784, name = "v1.0.0" }))
  eq({ t.short_revision, t.total_size, t.digest:sub(1, 7) }, { "d7a3cfda9", 102400, "sha256:" })
  eq(select(2, H.await(registry.tag({ host = HOST, project = P, repository_id = 3659784, name = "nope" }))).kind, "not_found")
  eq(select(2, H.await(registry.tags({ host = HOST, project = P }))).kind, "validation")
end

return T
