local milestone = require("gg.models.milestone")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["from_graphql: project milestone"] = function()
  local m = milestone.from_graphql({
    id = "gid://gitlab/Milestone/5",
    iid = "2",
    title = "v2",
    state = "closed",
    startDate = vim.NIL,
    dueDate = "2026-01-31T00:00:00Z",
    expired = true,
    webPath = "/gitlab/g/r/-/milestones/2",
    project = { fullPath = "g/r" },
    group = vim.NIL,
    createdAt = "2025-01-01T00:00:00Z",
    updatedAt = "2025-02-01T00:00:00Z",
  }, { origin = "https://h.example.com" })
  eq(m, {
    id = 5,
    iid = 2,
    title = "v2",
    state = "closed",
    due_date = "2026-01-31",
    web_url = "https://h.example.com/gitlab/g/r/-/milestones/2",
    project = "g/r",
    expired = true,
    created_at = "2025-01-01T00:00:00Z",
    updated_at = "2025-02-01T00:00:00Z",
  })
end

T["issue_stats: mapped from stats, nil when missing or partial"] = function()
  local node = { id = "gid://gitlab/Milestone/5", title = "v2" }
  node.stats = { totalIssuesCount = 6, closedIssuesCount = 2 }
  eq(milestone.ref_from_graphql(node).issue_stats, { total = 6, closed = 2 })
  eq(milestone.from_graphql(node).issue_stats, { total = 6, closed = 2 })
  node.stats = { totalIssuesCount = 0, closedIssuesCount = 0 }
  eq(milestone.ref_from_graphql(node).issue_stats, { total = 0, closed = 0 })
  node.stats = vim.NIL
  eq(milestone.ref_from_graphql(node).issue_stats, nil)
  node.stats = { totalIssuesCount = 6, closedIssuesCount = vim.NIL }
  eq(milestone.ref_from_graphql(node).issue_stats, nil)
  node.stats = nil
  eq(milestone.ref_from_graphql(node).issue_stats, nil)
  -- REST has no stats on milestone objects
  eq(milestone.ref_from_rest({ id = 1, title = "t" }).issue_stats, nil)
end

T["from_rest and ref_from_rest"] = function()
  local raw = { id = 1, iid = 1, project_id = 3, title = "t", description = "d", state = "active", due_date = "2026-02-01", start_date = vim.NIL, expired = false, web_url = "https://gitlab.example.com/g/r/-/milestones/1" }
  local m = milestone.from_rest(raw, { project = "g/r" })
  eq({ m.project, m.group, m.description, m.expired, m.due_date }, { "g/r", nil, "d", false, "2026-02-01" })
  eq(milestone.ref_from_rest(raw).web_url, "https://gitlab.example.com/g/r/-/milestones/1")
  eq(milestone.from_rest(nil), nil)
  eq(milestone.from_graphql(vim.NIL), nil)
end

return T
