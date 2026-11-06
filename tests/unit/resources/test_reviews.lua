local H = require("tests.helpers")
local fake_backend = require("gg.transport.backends.fake")
local reviews = require("gg.resources.reviews")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P, MP = H.TEST_HOST, "gitlab-org/cli", "my-group/my-project"
local MR = { host = HOST, project = MP, iid = 12 }

local function with(extra)
  return vim.tbl_extend("force", MR, extra)
end

T["reviewers: real gitlab.com review states"] = function()
  local fake = H.fake({ "graphql/reviews/reviewers.json" })
  local res = H.await(reviews.reviewers({ host = HOST, project = P, iid = 4338 }))
  eq(#res.reviewers, 2)
  eq(res.reviewers[1].role, "reviewer")
  eq(res.reviewers[1].review_state, "approved")
  eq(res.reviewers[1].approved, true)
  eq(res.reviewers[1].user.username, "user-1")
  eq(res.truncated, nil)
  eq(fake:last().variables, { fullPath = P, iid = "4338" })
end

T["reviewers: approvers who are not reviewers are participants"] = function()
  local fake = H.fake()
  local fx = fake_backend.read(H.path("tests/fixtures/graphql/reviews/reviewers.json"))[1]
  local mr = fx.response.body.data.project.mergeRequest
  table.insert(mr.approvedBy.nodes, { id = "gid://gitlab/User/99", username = "user-9", name = "Test User 9", state = "active", webUrl = "https://gitlab.example.com/user-9" })
  mr.reviewers.nodes[2].mergeRequestInteraction = { reviewState = "REQUESTED_CHANGES", approved = false }
  fake:add(fx)
  local res = H.await(reviews.reviewers({ host = HOST, project = P, iid = 4338 }))
  eq(#res.reviewers, 3)
  eq({ res.reviewers[2].review_state, res.reviewers[2].approved }, { "requested_changes", false })
  eq(res.reviewers[3], {
    user = { id = 99, username = "user-9", name = "Test User 9", state = "active", web_url = "https://gitlab.example.com/user-9" },
    role = "participant",
    review_state = "approved",
    approved = true,
  })
end

T["drafts: pages, empty positions dropped"] = function()
  H.fake({ "rest/reviews/drafts.json" })
  local res = H.await(reviews.drafts_all(MR, { limit = 10, per_page = 2 }))
  eq(#res.items, 3)
  eq(res.truncated, false)
  eq(res.items[1].position, nil)
  eq(res.items[2].discussion_id, "6a9c1750b37d513a43987b574953fceb50b03ce7")
  eq(res.items[3].position.new_line, 10)
  eq(res.items[3].line_code, "588440f66559714280628a4f9799f0c4eb880a4a_10_10")
end

T["create_draft, edit_draft, delete_draft"] = function()
  local fake = H.fake({ "rest/reviews/drafts.json" })
  local d = H.await(reviews.create_draft(with({ note = "Needs a test", in_reply_to_discussion_id = "6a9c1750b37d513a43987b574953fceb50b03ce7" })))
  eq({ d.id, d.note }, { 8, "Needs a test" })
  local e = H.await(reviews.edit_draft(with({ draft_id = 8, note = "Needs two tests" })))
  eq(e.note, "Needs two tests")
  eq(H.await(reviews.delete_draft(with({ draft_id = 5 }))), true)
  eq(fake:last().method, "DELETE")
end

T["discard_drafts: stops at the first error and reports how many were deleted"] = function()
  local fake = H.fake({ "rest/reviews/drafts.json" })
  local _, err = H.await(reviews.discard_drafts(MR, { limit = 10, per_page = 2 }))
  eq(err.kind, "not_found")
  eq(err.details.deleted, 2)
  eq(err.details.draft_id, 7)
  local deletes = vim.tbl_filter(function(r)
    return r.method == "DELETE"
  end, fake:requests())
  eq(#deletes, 3)
end

T["discard_drafts: all deleted"] = function()
  local fake = H.fake()
  fake:add({ request = { path = "/api/v4/projects/my-group%2Fmy-project/merge_requests/12/draft_notes", method = "GET" }, response = { body = { { id = 5, note = "a" }, { id = 6, note = "b" } } } })
  fake:add({ request = { path = "/api/v4/projects/my-group%2Fmy-project/merge_requests/12/draft_notes/5", method = "DELETE" }, response = { status = 204 } })
  fake:add({ request = { path = "/api/v4/projects/my-group%2Fmy-project/merge_requests/12/draft_notes/6", method = "DELETE" }, response = { status = 204 } })
  eq(H.await(reviews.discard_drafts(MR, { limit = 10 })), { deleted = 2, truncated = false })
  eq(select(2, H.await(reviews.discard_drafts(MR, {}))).details.key, "limit")
end

T["publish: bulk_publish with note and reviewer_state"] = function()
  local fake = H.fake({ "rest/reviews/drafts.json" })
  eq(H.await(reviews.publish(with({ note = "Overall looks good", reviewer_state = "requested_changes" }))), true)
  eq(fake:last().path, "/api/v4/projects/my-group%2Fmy-project/merge_requests/12/draft_notes/bulk_publish")
  eq(select(2, H.await(reviews.publish(with({ reviewer_state = "approved" })))).kind, "validation")
end

T["approve: with sha; sha mismatch is validation"] = function()
  H.fake({ "rest/reviews/drafts.json" })
  eq(H.await(reviews.approve(with({ sha = "4803c71e6b1833ca72b8b26ef2ecd5adc8a38031" }))), { approvals_required = 2, approvals_left = 1 })
  local _, err = H.await(reviews.approve({ host = HOST, project = MP, iid = 13 }))
  eq({ err.kind, err.status }, { "validation", 409 })
end

T["errors"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "MrReviewers" }, response = { body = { data = { project = { mergeRequest = vim.NIL } } } } })
  fake:add({ request = { path = "/api/v4/projects/my-group%2Fmy-project/merge_requests/12/draft_notes" }, response = { status = 403, body = { message = "403 Forbidden" } } })
  eq(select(2, H.await(reviews.reviewers({ host = HOST, project = P, iid = 1 }))).kind, "not_found")
  eq(select(2, H.await(reviews.drafts(MR))).kind, "forbidden")
  eq(select(2, H.await(reviews.edit_draft(with({ draft_id = 1 })))).kind, "validation")
end

return T
