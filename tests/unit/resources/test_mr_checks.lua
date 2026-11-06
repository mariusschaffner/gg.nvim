-- Pagination: not applicable (mr_checks has no list call).
local H = require("tests.helpers")
local checks = require("gg.resources.mr_checks")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P = H.TEST_HOST, "gitlab-org/cli"

local SCHEMA_ERROR = {
  request = { operation = "MrChecksFull" },
  response = { body = { errors = { { message = "Field 'mergeabilityChecks' doesn't exist on type 'MergeRequest'", extensions = { code = "undefinedField" } } } } },
  meta = { source = "test" },
}

T["get: real gitlab.com readiness with the per-check list"] = function()
  local fake = H.fake({ "graphql/mr_checks/full.json" })
  local c = H.await(checks.get({ host = HOST, project = P, iid = 4338 }))
  eq(c.draft, false)
  eq(c.mergeable, false)
  eq(c.detailed_merge_status, "ci_must_pass")
  eq(c.discussions_resolved, true)
  eq(c.has_conflicts, false)
  eq(c.head_pipeline_status, "failed")
  eq({ c.approved, c.approvals_required, c.approvals_left }, { true, 2, 0 })
  eq({ c.resolvable_discussions, c.resolved_discussions }, { 6, 6 })
  eq(#c.checks, 18)
  eq(c.checks[12], { identifier = "ci_must_pass", status = "failed" })
  eq(c.fallback, false)
  eq(#fake:requests(), 1)
end

T["get: falls back to the base query on a schema error"] = function()
  local fake = H.fake()
  fake:add(SCHEMA_ERROR):load("graphql/mr_checks/base.json")
  local c = H.await(checks.get({ host = HOST, project = P, iid = 4338 }))
  eq(c.fallback, true)
  eq(c.detailed_merge_status, "ci_must_pass")
  eq(c.checks, nil)
  eq(c.approved, nil)
  eq(#fake:requests(), 2)
  eq(fake:requests()[2].operation, "MrChecksBase")
end

T["get: no fallback for auth, network or other GraphQL errors"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "MrChecksFull", variables = { iid = "1" } }, response = { status = 401, body = { message = "401 Unauthorized" } } })
  fake:add({ request = { operation = "MrChecksFull", variables = { iid = "2" } }, response = { error = { kind = "network" } } })
  fake:add({ request = { operation = "MrChecksFull", variables = { iid = "3" } }, response = { body = { errors = { { message = "Timeout on validation of query" } } } } })
  fake:add({ request = { operation = "MrChecksBase" }, response = { body = { data = {} } }, ["repeat"] = true })
  eq(select(2, H.await(checks.get({ host = HOST, project = P, iid = 1 }))).kind, "auth")
  eq(select(2, H.await(checks.get({ host = HOST, project = P, iid = 2 }))).kind, "network")
  eq(select(2, H.await(checks.get({ host = HOST, project = P, iid = 3 }))).kind, "graphql")
  for _, r in ipairs(fake:requests()) do
    eq(r.operation, "MrChecksFull")
  end
end

T["get: a missing merge request is not_found"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "MrChecksFull" }, response = { body = { data = { project = { mergeRequest = vim.NIL } } } } })
  eq(select(2, H.await(checks.get({ host = HOST, project = P, iid = 9 }))).kind, "not_found")
  eq(select(2, H.await(checks.get({ host = HOST, project = P }))).kind, "validation")
  eq(#fake:requests(), 1)
end

return T
