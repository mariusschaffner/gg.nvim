local H = require("tests.helpers")
local branches = require("gg.resources.branches")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P = H.TEST_HOST, "gitlab-org/cli"

local function names(items)
  return vim.tbl_map(function(b)
    return b.name
  end, items)
end

T["list: real gitlab.com branches, encoded path, search"] = function()
  local fake = H.fake({ "rest/branches/list.json" })
  local page = H.await(branches.list({ host = HOST, project = P, search = "fix" }, { per_page = 2 }))
  eq(names(page.items), { "637331-maven-mirror-prefix-coordinates", "637331-poc-full-fix" })
  eq(page.next_cursor, "o:2")
  local b = page.items[1]
  eq(b.commit_sha:match("^%x+$") ~= nil, true)
  eq(b.default, false)
  eq(type(b.protected), "boolean")
  eq(b.web_url:find("https://gitlab.com/gitlab-org/cli/-/tree/", 1, true), 1)
  eq(fake:last().path, "/api/v4/projects/gitlab-org%2Fcli/repository/branches")
end

T["list_all: across pages, truncated"] = function()
  local fake = H.fake({ "rest/branches/list.json" })
  local res = H.await(branches.list_all({ host = HOST, project = P, search = "fix" }, { limit = 4, per_page = 2 }))
  eq(#res.items, 4)
  eq(res.truncated, true)
  eq(#fake:requests(), 2)
end

T["related_to_issue: server-side prefix search"] = function()
  local fake = H.fake({ "rest/branches/related.json" })
  local page = H.await(branches.related_to_issue({ host = HOST, project = P, iid = 7574 }))
  eq(names(page.items), { "7574-test-and-fix-stacked-diffs-in-forks" })
  eq(page.next_cursor, nil)
  eq(fake:last().query, { page = "1", per_page = "100", search = "^7574-" })
end

T["create"] = function()
  local fake = H.fake({ "rest/branches/create.json" })
  local b = H.await(branches.create({ host = HOST, project = "my-group/my-project", branch = "14-issues-with-auth", ref = "main" }))
  eq(b, {
    name = "14-issues-with-auth",
    commit_sha = "7b5c3cc8be40ee161ae89a06bba6229da1032a0c",
    commit_title = "add projects API",
    committed_date = "2012-06-28T03:44:20-07:00",
    default = false,
    protected = false,
    merged = false,
    can_push = true,
    web_url = "https://gitlab.example.com/my-group/my-project/-/tree/14-issues-with-auth",
  })
  eq(fake:last().method, "POST")
end

T["errors"] = function()
  H.fake({ "rest/branches/create.json" })
  local _, e1 = H.await(branches.create({ host = HOST, project = "my-group/my-project", branch = "main", ref = "main" }))
  eq({ e1.kind, e1.message }, { "validation", "400 Bad Request: Branch already exists" })
  eq(select(2, H.await(branches.list({ host = HOST, project = "nope/missing" }))).kind, "not_found")
  eq(select(2, H.await(branches.create({ host = HOST, project = "my-group/readonly", branch = "x", ref = "main" }))).kind, "forbidden")
  eq(select(2, H.await(branches.list({ host = HOST, project = P, search = "a", regex = "b" }))).kind, "validation")
  eq(select(2, H.await(branches.related_to_issue({ host = HOST, project = P }))).kind, "validation")
end

return T
