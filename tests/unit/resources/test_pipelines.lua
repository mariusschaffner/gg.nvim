local H = require("tests.helpers")
local fake_backend = require("gg.transport.backends.fake")
local pipelines = require("gg.resources.pipelines")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P, MP = H.TEST_HOST, "gitlab-org/cli", "my-group/my-project"
local PID = 3035060733
local GID = "gid://gitlab/Ci::Pipeline/3035060733"

T["list (project): request shape and summary stages"] = function()
  local fake = H.fake({ "graphql/pipelines/list_project.json" })
  local page = H.await(pipelines.list({ host = HOST, project = P, ref = "main" }, { per_page = 2 }))
  eq(#page.items, 2)
  local p = page.items[1]
  eq(p.id, PID)
  eq(p.project, P)
  eq(p.status, "success")
  eq(p.ref, "main")
  eq(#p.short_sha, 8)
  eq(p.source, "push")
  eq(p.web_url, "https://gitlab.example.com/gitlab-org/cli/-/pipelines/3035060733")
  eq(p.stages[1], { name = "application-security-testing", status = "success" })
  eq(p.truncated, nil)
  eq(fake:last().variables, { fullPath = P, first = 2, ref = "main" })
end

T["list_all (project): two pages, truncated"] = function()
  local fake = H.fake({ "graphql/pipelines/list_project.json" })
  local res = H.await(pipelines.list_all({ host = HOST, project = P, ref = "main" }, { limit = 3, per_page = 2 }))
  eq(#res.items, 3)
  eq(res.truncated, true)
  eq(#fake:requests(), 2)
end

T["list (project): tag flag, warnings and merge request"] = function()
  H.fake({ "graphql/pipelines/list_project_fields.json" })
  local page = H.await(pipelines.list({ host = HOST, project = P }, { per_page = 2 }))
  local mr, branch = page.items[1], page.items[2]
  eq({ mr.ref, mr.tag, mr.source, mr.merge_request, mr.warnings }, { "refs/merge-requests/4348/merge", false, "merge_request_event", { iid = 4348 }, false })
  eq(mr.ref_path, "refs/heads/bl-1781-rumdl-md055-md056")
  eq({ branch.tag, branch.merge_request }, { false, nil })
  eq(page.next_cursor ~= nil, true)
  local tags = H.await(pipelines.list({ host = HOST, project = P, scope = "tags" }))
  eq({ tags.items[1].ref, tags.items[1].tag }, { "v1.128.0", true })
end

T["list (project): ids select pipelines by global ID"] = function()
  local fake = H.fake()
  fake:add(fake_backend.read(H.path("tests/fixtures/graphql/pipelines/list_project_fields.json"))[3])
  local page = H.await(pipelines.list({ host = HOST, project = P, ids = { 3046451100, 3046428384 } }))
  eq(vim.tbl_map(function(p)
    return p.status
  end, page.items), { "running", "success" })
  eq(fake:last().variables.ids, { "gid://gitlab/Ci::Pipeline/3046451100", "gid://gitlab/Ci::Pipeline/3046428384" })
  local many = {}
  for i = 1, pipelines.MAX_IDS + 1 do
    many[i] = i
  end
  eq(select(2, H.await(pipelines.list({ host = HOST, project = P, ids = many }))).kind, "validation")
  eq(select(2, H.await(pipelines.list({ host = HOST, project = P, ids = {} }))).kind, "validation")
  eq(select(2, H.await(pipelines.list({ host = HOST, project = P, ids = { "x" } }))).kind, "validation")
  eq(select(2, H.await(pipelines.list({ host = HOST, project = P, mr_iid = 1, ids = { 1 } }))).kind, "validation")
end

T["list (project): drops refPath and mergeRequest on a schema error, per call"] = function()
  local fake = H.fake()
  local fx = fake_backend.read(H.path("tests/fixtures/graphql/pipelines/list_project.json"))[1]
  fake:add({
    meta = { source = "test" },
    request = { operation = "PipelinesListProject" },
    response = { body = { errors = { { message = "Field 'refPath' doesn't exist on type 'Pipeline'" } } } },
    ["repeat"] = true,
  })
  fx.request.operation = "PipelinesListProjectBase"
  fx["repeat"] = true
  fake:add(fx)
  local page = H.await(pipelines.list({ host = HOST, project = P, ref = "main" }, { per_page = 2 }))
  eq(#page.items, 2)
  eq({ page.items[1].tag, page.items[1].merge_request }, { nil, nil })
  eq(vim.tbl_map(function(r)
    return r.operation
  end, fake:requests()), { "PipelinesListProject", "PipelinesListProjectBase" })
  H.await(pipelines.list({ host = HOST, project = P, ref = "main" }, { per_page = 2 }))
  eq(fake:requests()[3].operation, "PipelinesListProject")
end

T["list (merge request)"] = function()
  local fake = H.fake({ "graphql/pipelines/list_mr.json" })
  local page = H.await(pipelines.list({ host = HOST, project = P, mr_iid = 4338 }, { per_page = 2 }))
  eq(#page.items >= 1, true)
  eq(fake:last().operation, "PipelinesListMr")
  eq(fake:last().variables, { fullPath = P, iid = "4338", first = 2 })
  eq(select(2, H.await(pipelines.list({ host = HOST, project = P, mr_iid = 1, ref = "main" }))).kind, "validation")
end

T["list: status and scope are upper-cased enums"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "PipelinesListProject" }, response = { body = { data = { project = { pipelines = { nodes = {}, pageInfo = { hasNextPage = false } } } } } } })
  H.await(pipelines.list({ host = HOST, project = P, status = "failed", scope = "branches", username = "user-1" }))
  eq(fake:last().variables, { fullPath = P, first = 50, status = "FAILED", scope = "BRANCHES", username = "user-1" })
end

T["get: by global ID"] = function()
  local fake = H.fake({ "graphql/pipelines/get.json" })
  local p = H.await(pipelines.get({ host = HOST, project = P, id = PID }))
  eq({ p.id, p.iid, p.total_jobs }, { PID, 16967, 19 })
  eq(fake:last().variables, { fullPath = P, id = GID })
end

T["graph: stage order, groups and job flags"] = function()
  H.fake({ "graphql/pipelines/graph.json" })
  local p = H.await(pipelines.graph({ host = HOST, project = P, id = PID }))
  local names = vim.tbl_map(function(s)
    return s.name
  end, p.stages)
  eq(names, { "application-security-testing", "checks", "test", "build", "release" })
  eq(#p.stages[4].groups, 4)
  eq(#p.stages[4].jobs, 6)
  local j = p.stages[1].jobs[1]
  eq({ j.id, j.name, j.stage, j.status }, { 17795132454, "dependency-scanning-profile-0", "application-security-testing", "success" })
  eq({ j.allow_failure, j.manual, j.playable, j.retryable, j.cancelable }, { true, false, false, true, false })
  eq(j.web_url, "https://gitlab.example.com/gitlab-org/cli/-/jobs/17795132454")
  eq(p.merge_request, nil)
  eq(p.truncated, nil)
end

T["graph: drops mergeRequest on a schema error, per call"] = function()
  local fake = H.fake()
  local fx = fake_backend.read(H.path("tests/fixtures/graphql/pipelines/graph.json"))[1]
  local schema_error = {
    meta = { source = "test" },
    request = { operation = "PipelineGraph" },
    response = { body = { errors = { { message = "Field 'mergeRequest' doesn't exist on type 'Pipeline'" } } } },
    ["repeat"] = true,
  }
  fx.request.operation = "PipelineGraphBase"
  fx["repeat"] = true
  fake:add(schema_error):add(fx)
  local p = H.await(pipelines.graph({ host = HOST, project = P, id = PID }))
  eq(#p.stages, 5)
  eq(vim.tbl_map(function(r)
    return r.operation
  end, fake:requests()), { "PipelineGraph", "PipelineGraphBase" })
  -- nothing is remembered: the next call tries the full query again
  H.await(pipelines.graph({ host = HOST, project = P, id = PID }))
  eq(fake:requests()[3].operation, "PipelineGraph")
end

T["graph: other errors do not fall back"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "PipelineGraph" }, response = { status = 401, body = { message = "401 Unauthorized" } } })
  eq(select(2, H.await(pipelines.graph({ host = HOST, project = P, id = PID }))).kind, "auth")
  eq(#fake:requests(), 1)
end

T["graph: truncated jobs are reported"] = function()
  local fake = H.fake()
  local fx = fake_backend.read(H.path("tests/fixtures/graphql/pipelines/graph.json"))[1]
  fx.response.body.data.project.pipeline.graph.nodes[4].groups.nodes[1].jobs.pageInfo.hasNextPage = true
  fake:add(fx)
  local p = H.await(pipelines.graph({ host = HOST, project = P, id = PID }))
  eq(p.truncated, { jobs = true })
end

T["retry and cancel (REST)"] = function()
  local fake = H.fake({ "rest/pipelines/actions.json" })
  local r = H.await(pipelines.retry({ host = HOST, project = MP, id = 46 }))
  eq({ r.id, r.status, r.project, r.short_sha }, { 46, "pending", MP, "a91957a8" })
  local c = H.await(pipelines.cancel({ host = HOST, project = MP, id = 46 }))
  eq(c.status, "canceled")
  eq(fake:last().method, "POST")
  eq(select(2, H.await(pipelines.retry({ host = HOST, project = MP, id = 47 }))).kind, "forbidden")
end

T["errors"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "PipelineGet" }, response = { body = { data = { project = { pipeline = vim.NIL } } } } })
  eq(select(2, H.await(pipelines.get({ host = HOST, project = P, id = 1 }))).kind, "not_found")
  eq(select(2, H.await(pipelines.list({ host = HOST, project = P, status = "green" }))).kind, "validation")
end

return T
