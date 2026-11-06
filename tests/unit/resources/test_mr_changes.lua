local H = require("tests.helpers")
local changes = require("gg.resources.mr_changes")
local diff = require("gg.models.diff")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P, MP = H.TEST_HOST, "gitlab-org/cli", "my-group/my-project"

T["commits: GraphQL, real gitlab.com commit"] = function()
  local fake = H.fake({ "graphql/mr_changes/commits.json" })
  local page = H.await(changes.commits({ host = HOST, project = P, iid = 4002 }, { per_page = 1 }))
  eq(#page.items, 1)
  local c = page.items[1]
  eq(c.sha:match("^%x+$") ~= nil, true)
  eq(#c.short_sha, 8)
  eq(c.author_name, "Test User 2")
  eq(c.author_email, "user1@example.com")
  eq(c.author.username, "user-1")
  eq(c.web_url:find("https://gitlab.com/gitlab-org/cli/-/commit/", 1, true), 1)
  eq(page.next_cursor:sub(1, 2), "g:")
  eq(fake:last().variables, { fullPath = P, iid = "4002", first = 1 })
end

T["commits_all: across pages, truncated"] = function()
  local fake = H.fake({ "graphql/mr_changes/commits.json" })
  local res = H.await(changes.commits_all({ host = HOST, project = P, iid = 4002 }, { limit = 2, per_page = 1 }))
  eq(#res.items, 2)
  eq(res.truncated, true)
  eq(#fake:requests(), 2)
end

T["diffs: REST /diffs pages (not the deprecated /changes)"] = function()
  local fake = H.fake({ "rest/mr_changes/diffs.json" })
  local res = H.await(changes.diffs_all({ host = HOST, project = P, iid = 4002 }, { limit = 10, per_page = 2 }))
  eq(#res.items, 4)
  eq(res.truncated, false)
  eq(res.items[1].new_path, "internal/config/file.go")
  eq(res.items[1].diff:sub(1, 2), "@@")
  eq(fake:requests()[1].path, "/api/v4/projects/gitlab-org%2Fcli/merge_requests/4002/diffs")
end

T["diffs: unidiff is passed through"] = function()
  local fake = H.fake()
  fake:add({ request = { path = "/api/v4/projects/1/merge_requests/2/diffs", query_contains = { unidiff = "true" } }, response = { body = {} } })
  H.await(changes.diffs({ host = HOST, project = 1, iid = 2, unidiff = true }))
  eq(fake:last().query.unidiff, "true")
end

T["diffstat: every status; nil counts for too-large files"] = function()
  H.fake({ "rest/mr_changes/versions_and_statuses.json" })
  local res = H.await(changes.diffstat({ host = HOST, project = MP, iid = 12 }, { limit = 50 }))
  eq(res.items, {
    { path = "README.md", status = "added", additions = 2, deletions = 0 },
    { path = "new.txt", old_path = "old.txt", status = "renamed", additions = 1, deletions = 1 },
    { path = "gone.lua", status = "deleted", additions = 0, deletions = 2 },
    { path = "big.json", status = "modified" },
    { path = "mode.sh", status = "modified", additions = 0, deletions = 0 },
  })
  eq(res.truncated, false)
end

T["diffstat on real diffs"] = function()
  H.fake({ "rest/mr_changes/diffs.json" })
  local res = H.await(changes.diffstat({ host = HOST, project = P, iid = 4002 }, { limit = 3, per_page = 2 }))
  eq(#res.items, 3)
  eq(res.truncated, true)
  eq(res.items[1].status, "modified")
  eq(res.items[1].additions > 0, true)
end

T["count_lines skips file headers"] = function()
  eq({ diff.count_lines("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n+c\n") }, { 2, 1 })
end

T["versions and latest_version"] = function()
  local fake = H.fake({ "rest/mr_changes/versions_and_statuses.json" })
  local v = H.await(changes.latest_version({ host = HOST, project = MP, iid = 12 }))
  eq(v.id, 110)
  eq(v.diff_refs, {
    base_sha = "eeb57dffe83deb686a60a71c16c32f71046868fd",
    head_sha = "33e2ee8579fda5bc36accc9c6fbd0b4fefda9e30",
    start_sha = "eeb57dffe83deb686a60a71c16c32f71046868fd",
  })
  eq(fake:last().query, { page = "1", per_page = "1" })
  local _, err = H.await(changes.latest_version({ host = HOST, project = MP, iid = 13 }))
  eq(err.kind, "not_found")
end

T["errors"] = function()
  local fake = H.fake({ "rest/mr_changes/versions_and_statuses.json" })
  fake:add({ request = { operation = "MrCommits" }, response = { body = { data = { project = { mergeRequest = vim.NIL } } } } })
  eq(select(2, H.await(changes.diffs({ host = HOST, project = MP, iid = 999 }))).kind, "not_found")
  eq(select(2, H.await(changes.commits({ host = HOST, project = MP, iid = 1 }))).kind, "not_found")
  eq(select(2, H.await(changes.diffstat({ host = HOST, project = MP, iid = 12 }, {}))).kind, "validation")
  eq(select(2, H.await(changes.diffs({ host = HOST, project = MP }))).kind, "validation")
end

return T
