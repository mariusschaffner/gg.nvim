local review = require("gg.models.review")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["draft_from_rest: an all-null position is no position"] = function()
  local d = review.draft_from_rest({ id = 1, note = "x", position = { position_type = "text", new_path = vim.NIL, old_path = vim.NIL } })
  eq(d.position, nil)
  eq(d.resolve_discussion, false)
  eq(review.draft_from_rest(vim.NIL), nil)
end

T["reviewers_from_graphql: truncation is reported"] = function()
  local list, truncated = review.reviewers_from_graphql({
    reviewers = { nodes = { { id = "gid://gitlab/User/1", username = "user-1", name = "Test User 1", mergeRequestInteraction = vim.NIL } }, pageInfo = { hasNextPage = true } },
    approvedBy = { nodes = {}, pageInfo = { hasNextPage = false } },
  })
  eq(#list, 1)
  eq({ list[1].review_state, list[1].approved }, { nil, false })
  eq(truncated, { reviewers = true })
end

return T
