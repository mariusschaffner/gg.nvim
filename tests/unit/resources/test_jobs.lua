local H = require("tests.helpers")
local jobs = require("gg.resources.jobs")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P, MP = H.TEST_HOST, "gitlab-org/cli", "my-group/my-project"

T["list: a pipeline's jobs, retried hidden by default"] = function()
  local fake = H.fake({ "graphql/jobs/list.json" })
  local page = H.await(jobs.list({ host = HOST, project = P, pipeline_id = 3035060733 }, { per_page = 2 }))
  eq(#page.items, 2)
  eq(page.items[1].name, "snapcraft_release_edge")
  eq(page.items[1].stage, "release")
  eq(page.next_cursor:sub(1, 2), "g:")
  eq(fake:last().variables, { fullPath = P, id = "gid://gitlab/Ci::Pipeline/3035060733", first = 2, retried = false })
end

T["list_all: two pages, truncated; statuses and retried"] = function()
  local fake = H.fake({ "graphql/jobs/list.json" })
  local res = H.await(jobs.list_all({ host = HOST, project = P, pipeline_id = 3035060733 }, { limit = 4, per_page = 2 }))
  eq(#res.items, 4)
  eq(res.truncated, true)
  fake:reset():add({ request = { operation = "JobsList" }, response = { body = { data = { project = { pipeline = { jobs = { nodes = {}, pageInfo = { hasNextPage = false } } } } } } } })
  H.await(jobs.list({ host = HOST, project = P, pipeline_id = 1, statuses = { "failed", "manual" }, include_retried = true }))
  eq(fake:last().variables, { fullPath = P, id = "gid://gitlab/Ci::Pipeline/1", first = 100, statuses = { "FAILED", "MANUAL" } })
end

T["get"] = function()
  local fake = H.fake({ "graphql/jobs/get.json" })
  local j = H.await(jobs.get({ host = HOST, project = P, id = 17795132454 }))
  eq({ j.id, j.name, j.status }, { 17795132454, "dependency-scanning-profile-0", "success" })
  eq(fake:last().variables, { fullPath = P, id = "gid://gitlab/Ci::Build/17795132454" })
end

T["trace: streamed to a callback, never buffered"] = function()
  local fake = H.fake({ "rest/jobs/trace_and_actions.json" })
  local chunks = {}
  local res = H.await(jobs.trace({ host = HOST, project = MP, id = 7, on_chunk = function(c)
    table.insert(chunks, c)
  end }))
  local log = table.concat(chunks)
  eq(log:find("Job succeeded", 1, true) ~= nil, true)
  eq(res.bytes, #log)
  eq(res.range_ignored, nil)
  eq(fake:last().headers.Range, nil)
end

T["trace: to a file"] = function()
  H.fake({ "rest/jobs/trace_and_actions.json" })
  local out = vim.fn.tempname() .. ".log"
  local res = H.await(jobs.trace({ host = HOST, project = MP, id = 7, output = out }))
  eq(res.bytes > 0, true)
  eq(H.read(out):find("make test", 1, true) ~= nil, true)
  os.remove(out)
end

T["trace: offset sends Range; 206 tail, 200 ignored, 416 nothing new"] = function()
  local fake = H.fake({ "rest/jobs/trace_and_actions.json" })
  local got = {}
  local cb = function(c)
    table.insert(got, c)
  end
  local r206 = H.await(jobs.trace({ host = HOST, project = MP, id = 8, offset = 100, on_chunk = cb }))
  eq(fake:last().headers.Range, "bytes=100-")
  eq({ r206.bytes, r206.range_ignored }, { 20, nil })
  local r200 = H.await(jobs.trace({ host = HOST, project = MP, id = 9, offset = 50, on_chunk = cb }))
  eq(r200.range_ignored, true)
  local r416 = H.await(jobs.trace({ host = HOST, project = MP, id = 10, offset = 120, on_chunk = cb }))
  eq(r416, { bytes = 0 })
  eq(table.concat(got), "new line of output\n\nthe whole log\n")
end

T["trace: validation and errors"] = function()
  H.fake({ "rest/jobs/trace_and_actions.json" })
  eq(select(2, H.await(jobs.trace({ host = HOST, project = MP, id = 7 }))).kind, "validation")
  eq(select(2, H.await(jobs.trace({ host = HOST, project = MP, id = 7, output = "/tmp/x", on_chunk = function() end }))).kind, "validation")
  eq(select(2, H.await(jobs.trace({ host = HOST, project = MP, id = 11, on_chunk = function() end }))).kind, "not_found")
end

T["retry, cancel, play"] = function()
  local fake = H.fake({ "rest/jobs/trace_and_actions.json" })
  local r = H.await(jobs.retry({ host = HOST, project = MP, id = 7 }))
  eq({ r.id, r.status, r.pipeline_id, r.user.username }, { 12, "pending", 46, "user-1" })
  eq(H.await(jobs.cancel({ host = HOST, project = MP, id = 7 })).status, "canceled")
  local p = H.await(jobs.play({ host = HOST, project = MP, id = 13, variables = { VERSION = 2, ENV = "staging" } }))
  eq({ p.id, p.manual }, { 13, true })
  eq(fake:last().json.job_variables_attributes, { { key = "ENV", value = "staging" }, { key = "VERSION", value = "2" } })
  local _, err = H.await(jobs.play({ host = HOST, project = MP, id = 14 }))
  eq(err.kind, "validation")
end

return T
