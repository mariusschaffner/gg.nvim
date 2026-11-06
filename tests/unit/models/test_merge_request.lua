local H = require("tests.helpers")
local fake = require("gg.transport.backends.fake")
local mr = require("gg.models.merge_request")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function gql_node()
  return fake.read(H.path("tests/fixtures/graphql/merge_requests/get.json"))[1].response.body.data.project.mergeRequest
end

T["from_graphql: every field of a real gitlab.com merge request"] = function()
  local m = mr.from_graphql(gql_node(), { origin = "https://gitlab.com" })
  eq(m.id, 543613929)
  eq(m.iid, 4002)
  eq(m.project, "gitlab-org/cli")
  eq(m.title, "fix(config): share local config across git worktrees")
  eq(m.description:sub(1, 26), "## What does this MR do an")
  eq(m.state, "merged")
  eq(m.draft, false)
  eq(m.author.username, "user-1")
  eq(#m.assignees, 1)
  eq(#m.reviewers, 2)
  eq(m.reviewers[1].id, 21826781)
  eq(#m.labels, 8)
  eq(m.labels[1].name, "Community contribution")
  eq(m.milestone, nil)
  eq(m.source_branch, "8568-share-local-config-across-worktrees")
  eq(m.target_branch, "main")
  eq({ m.source_project_id, m.target_project_id }, { 45049979, 34675721 })
  eq(m.sha, "fc1a118b066a56deac5b26a27e336932a0356c0f")
  eq(m.diff_refs, {
    base_sha = "1ab692e5cfc809947e1852c77e0692e09b2eacde",
    head_sha = "fc1a118b066a56deac5b26a27e336932a0356c0f",
    start_sha = "1ab692e5cfc809947e1852c77e0692e09b2eacde",
  })
  eq(m.merge_status, "can_be_merged")
  eq(m.detailed_merge_status, "not_open")
  eq(m.has_conflicts, false)
  eq(m.user_notes_count, 15)
  eq({ m.should_remove_source_branch, m.force_remove_source_branch, m.squash }, { true, true, true })
  eq(m.web_url, "https://gitlab.com/gitlab-org/cli/-/merge_requests/4002")
  eq(m.references, { short = "!4002", full = "gitlab-org/cli!4002" })
  eq(m.created_at, "2026-10-06T09:03:04Z")
  eq(m.merged_at, "2026-11-06T05:30:42Z")
  eq(m.closed_at, nil)
  eq(m.subscribed, false)
  eq(m.truncated, nil)
end

T["from_graphql: truncated reviewers are reported"] = function()
  local n = vim.deepcopy(gql_node())
  n.reviewers.pageInfo.hasNextPage = true
  eq(mr.from_graphql(n).truncated, { reviewers = true })
end

T["from_rest: real gitlab.com REST shape"] = function()
  local body = fake.read(H.path("tests/fixtures/rest/merge_requests/list_all.json"))[1].response.body
  local m = mr.from_rest(body[1])
  eq(type(m.id), "number")
  eq(type(m.iid), "number")
  eq(m.project, "gitlab-org/cli")
  eq(m.state, "merged")
  eq(m.draft, false)
  eq(type(m.labels[1].color), "string")
  eq(m.target_branch ~= nil, true)
  eq(m.references.full:match("^gitlab%-org/cli!%d+$") ~= nil, true)
end

T["from_rest: work_in_progress fallback and empty lists"] = function()
  local m = mr.from_rest({ id = 1, iid = 2, work_in_progress = true, labels = { "a" } })
  eq(m.draft, true)
  eq(m.labels, { { name = "a" } })
  eq(m.assignees, {})
  eq(m.reviewers, {})
  eq(mr.from_rest(vim.NIL), nil)
end

return T
