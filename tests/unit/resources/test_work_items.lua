-- Pagination: not applicable (work_items has no list call).
local H = require("tests.helpers")
local work_items = require("gg.resources.work_items")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P = H.TEST_HOST, "my-group/my-project"

T["dates: real gitlab.com work item without dates"] = function()
  local fake = H.fake({ "graphql/work_items/dates_empty.json" })
  local d = H.await(work_items.dates({ host = HOST, project = "gitlab-org/cli", iid = 8279 }))
  eq(d, { work_item_id = "gid://gitlab/WorkItem/188940826", iid = 8279 })
  eq(fake:last().variables, { fullPath = "gitlab-org/cli", iid = "8279" })
end

T["dates: with dates"] = function()
  H.fake({ "graphql/work_items/update.json" })
  local d = H.await(work_items.dates({ host = HOST, project = P, iid = 14 }))
  eq(d, { work_item_id = "gid://gitlab/WorkItem/85", iid = 14, start_date = "2026-11-02", due_date = "2026-11-20" })
end

T["update_dates: looks up the ID, sets one date, clears the other"] = function()
  local fake = H.fake({ "graphql/work_items/update.json" })
  local d = H.await(work_items.update_dates({ host = HOST, project = P, iid = 14, due_date = "2026-12-01", start_date = false }))
  eq(d.due_date, "2026-12-01")
  eq(d.start_date, nil)
  eq(#fake:requests(), 2)
  local rec = fake:last()
  eq(rec.operation, "WorkItemUpdateDates")
  -- the cleared date is sent as an explicit null
  eq(rec.body:find('"startDate":null', 1, true) ~= nil, true)
  eq(rec.variables.dueDate, "2026-12-01")
end

T["update_dates: with a known ID there is no lookup; untouched dates are not sent"] = function()
  local fake = H.fake({ "graphql/work_items/update.json" })
  H.await(work_items.update_dates({ host = HOST, project = P, iid = 14, work_item_id = "gid://gitlab/WorkItem/85", due_date = "2026-12-01" }))
  eq(#fake:requests(), 1)
  -- the quoted key only appears in the variables (the query text has $startDate)
  eq(fake:last().body:find('"startDate"', 1, true), nil)
end

T["errors: payload errors, not found, validation"] = function()
  H.fake({ "graphql/work_items/update.json" })
  local _, e1 = H.await(work_items.update_dates({ host = HOST, project = P, iid = 15, work_item_id = "gid://gitlab/WorkItem/86", due_date = false }))
  eq(e1.kind, "validation")
  eq(e1.message, "Start date must be before the due date")
  local _, e2 = H.await(work_items.dates({ host = HOST, project = P, iid = 404 }))
  eq(e2.kind, "not_found")
  local _, e3 = H.await(work_items.update_dates({ host = HOST, project = P, iid = 14 }))
  eq(e3.kind, "validation")
  local _, e4 = H.await(work_items.update_dates({ host = HOST, project = P, iid = 14, due_date = "12/01/2026" }))
  eq(e4.kind, "validation")
end

return T
