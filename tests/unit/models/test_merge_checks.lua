local checks = require("gg.models.merge_checks")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["base query fields only"] = function()
  local c = checks.from_graphql({ draft = true, detailedMergeStatus = "DRAFT_STATUS", mergeableDiscussionsState = false, conflicts = true, headPipeline = vim.NIL }, true)
  eq(c, { draft = true, detailed_merge_status = "draft_status", discussions_resolved = false, has_conflicts = true, fallback = true })
  eq(checks.from_graphql(vim.NIL), nil)
end

return T
