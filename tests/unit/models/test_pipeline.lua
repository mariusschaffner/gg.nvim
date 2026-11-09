local job = require("gg.models.job")
local pipeline = require("gg.models.pipeline")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["pipeline from_graphql: summary stages, truncation"] = function()
  local p = pipeline.from_graphql({
    id = "gid://gitlab/Ci::Pipeline/9",
    iid = "3",
    status = "RUNNING",
    path = "/g/r/-/pipelines/9",
    stages = { nodes = { { name = "build", status = "running" } }, pageInfo = { hasNextPage = true } },
    mergeRequest = { iid = "5", title = "MR" },
  }, { origin = "https://h.example.com", project = "g/r" })
  eq({ p.id, p.iid, p.status, p.project, p.web_url }, { 9, 3, "running", "g/r", "https://h.example.com/g/r/-/pipelines/9" })
  eq(p.stages, { { name = "build", status = "running" } })
  eq(p.merge_request, { iid = 5, title = "MR" })
  eq(p.truncated, { stages = true })
end

T["pipeline: tag flag from refPath (GraphQL) and tag (REST), warnings"] = function()
  local function g(ref_path, warnings)
    return pipeline.from_graphql({ id = "gid://gitlab/Ci::Pipeline/1", status = "SUCCESS", refPath = ref_path, warnings = warnings })
  end
  eq({ g("refs/tags/v1.0").tag, g("refs/heads/main").tag, g(nil).tag, g(vim.NIL).tag }, { true, false, nil, nil })
  eq({ g(nil, true).warnings, g(nil, false).warnings, g(nil, nil).warnings }, { true, false, nil })
  -- a list node: the merge request has no title
  eq(pipeline.from_graphql({ id = "gid://gitlab/Ci::Pipeline/1", mergeRequest = { iid = "7" } }).merge_request, { iid = 7 })
  eq(pipeline.from_graphql({ id = "gid://gitlab/Ci::Pipeline/1", mergeRequest = vim.NIL }).merge_request, nil)
  eq({ pipeline.from_rest({ id = 1, tag = true }).tag, pipeline.from_rest({ id = 1, tag = false }).tag, pipeline.from_rest({ id = 1 }).tag }, { true, false, nil })
end

T["job from_rest: manual, artifacts, pipeline id"] = function()
  local j = job.from_rest({
    id = 7,
    name = "deploy",
    stage = "deploy",
    status = "manual",
    when = "manual",
    allow_failure = false,
    pipeline = { id = 46 },
    commit = { short_id = "a91957a8" },
    artifacts = { { file_type = "archive", filename = "artifacts.zip", size = 1000, file_format = "zip" } },
    web_url = "https://gitlab.example.com/g/r/-/jobs/7",
  })
  eq({ j.id, j.manual, j.pipeline_id, j.short_sha }, { 7, true, 46, "a91957a8" })
  eq(j.artifacts, { { file_type = "archive", filename = "artifacts.zip", size = 1000, file_format = "zip" } })
  eq(job.from_graphql(vim.NIL), nil)
  eq(pipeline.from_rest(nil), nil)
end

return T
