-- The pipelines of the UI mockup (docs/pipeline_table_design.png) as raw
-- GraphQL nodes, plus a second page, the project and the open merge
-- requests as fake-backend responses. Synthetic data: no real names,
-- hosts or e-mails.
local MR = require("tests.support.mr_data")
local pipeline_model = require("gg.models.pipeline")

local D = {}

D.HOST = MR.HOST
D.PROJECT = MR.PROJECT
D.NOW = 1794225600 -- 2026-11-09T12:00:00Z
D.PROJECT_ID = 42

local function iso(t)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

local STAGE_NAMES = { "build", "test", "plan", "deploy" }

local function stages(list)
  local nodes = {}
  for i, s in ipairs(list) do
    nodes[i] = { name = STAGE_NAMES[i] or ("stage" .. i), status = s }
  end
  return { nodes = nodes, pageInfo = { hasNextPage = false } }
end

---@class tests.PipelineSpec
---@field id integer
---@field status string GitLab status, lowercase
---@field ref string branch or tag name
---@field sha string 8 characters
---@field title string commit title
---@field source string
---@field stages string[]
---@field ago integer seconds before `now` it started
---@field mr? integer a merge request pipeline for this IID
---@field tag? boolean
---@field warnings? boolean
---@field user? string

--- A raw PipelinesListProject node.
---@param s tests.PipelineSpec
---@param now? integer default D.NOW
function D.node(s, now)
  now = now or D.NOW
  local ref = s.mr and ("refs/merge-requests/%d/head"):format(s.mr) or s.ref
  local started = now - s.ago
  return {
    id = "gid://gitlab/Ci::Pipeline/" .. s.id,
    iid = tostring(s.id - 4000),
    status = s.status:upper(),
    ref = ref,
    refPath = (s.tag and "refs/tags/" or "refs/heads/") .. s.ref,
    sha = s.sha .. string.rep("0", 32),
    shortSha = s.sha,
    source = s.source,
    createdAt = iso(started - 5),
    startedAt = iso(started),
    finishedAt = vim.NIL,
    duration = vim.NIL,
    queuedDuration = 1,
    path = "/" .. D.PROJECT .. "/-/pipelines/" .. s.id,
    totalJobs = #s.stages,
    retryable = false,
    cancelable = false,
    warnings = s.warnings or false,
    user = { id = "gid://gitlab/User/7", username = s.user or "user-ma", name = "Test User 1", state = "active", webUrl = "https://" .. D.HOST .. "/user-ma" },
    commit = { title = s.title },
    stages = stages(s.stages),
    mergeRequest = s.mr and { iid = tostring(s.mr) } or vim.NIL,
  }
end

--- The mockup's eight pipelines, newest first.
---@return tests.PipelineSpec[]
function D.specs()
  return {
    { id = 4821, status = "running", ref = "feat/winrm-https", sha = "a1f3c9e0", title = "Add HTTPS listener task", source = "push", stages = { "success", "running", "pending", "pending" }, ago = 120 },
    { id = 4819, status = "failed", ref = "feat/oci-edge-lb", sha = "7c2e0b14", title = "Add backend set health checks", source = "push", stages = { "success", "failed", "skipped", "skipped" }, ago = 3600 },
    { id = 4817, status = "manual", ref = "feat/rotate-tf-creds", sha = "3d9aa47b", title = "Move state key to CI variable", source = "push", stages = { "success", "success", "success", "manual" }, ago = 7200 },
    { id = 4815, status = "success", ref = "feat/dns01-wildcard", mr = 85, sha = "e58b21f3", title = "Handle CAA records", source = "merge_request_event", stages = { "success", "success", "success", "manual" }, ago = 3 * 3600 },
    { id = 4812, status = "success", ref = "main", sha = "9f0c3d21", title = "Merge !82 Pin PowerShell modules", source = "push", stages = { "success", "success", "success", "success" }, ago = 8 * 3600 },
    { id = 4810, status = "canceled", ref = "fix/backup-weekend", sha = "1b77e40c", title = "Shift schedule to 02:30", source = "push", stages = { "success", "canceled", "skipped", "skipped" }, ago = 86400 + 600 },
    { id = 4808, status = "success", ref = "main", sha = "9f0c3d21", title = "nightly drift check", source = "schedule", stages = { "success", "success", "success", "skipped" }, ago = 86400 + 7200 },
    { id = 4806, status = "failed", ref = "main", sha = "c4a81de9", title = "nightly drift check", source = "schedule", stages = { "success", "success", "failed", "skipped" }, ago = 2 * 86400 + 600, user = "user-sf" },
  }
end

--- The second page: an older tag pipeline and a pipeline with warnings.
---@return tests.PipelineSpec[]
function D.specs_page2()
  return {
    { id = 4800, status = "success", ref = "v1.4.0", tag = true, sha = "0aa1b2c3", title = "Release v1.4.0", source = "push", stages = { "success", "success" }, ago = 3 * 86400 },
    { id = 4799, status = "success", ref = "main", sha = "0bb1c2d3", title = "Allow lint failures", source = "web", stages = { "success", "failed" }, ago = 3 * 86400 + 60, warnings = true },
  }
end

--- Raw nodes of `specs` started relative to `now`.
---@param specs? tests.PipelineSpec[]
---@param now? integer
function D.nodes(specs, now)
  return vim.tbl_map(function(s)
    return D.node(s, now)
  end, specs or D.specs())
end

--- The nodes as gg.Pipeline models.
---@param specs? tests.PipelineSpec[]
---@param now? integer
---@return gg.Pipeline[]
function D.pipelines(specs, now)
  return vim.tbl_map(function(n)
    return pipeline_model.from_graphql(n, { origin = "https://" .. D.HOST, project = D.PROJECT })
  end, D.nodes(specs, now))
end

local function body(nodes, next_cursor)
  return { data = { project = { pipelines = { nodes = nodes, pageInfo = { hasNextPage = next_cursor ~= nil, endCursor = next_cursor or vim.NIL } } } } }
end

--- The first page (and, with `next_cursor`, a second one behind it).
---@param opts? { now?: integer, next_cursor?: string, delay?: integer }
function D.list_responses(opts)
  opts = opts or {}
  local out = {
    {
      request = { operation = "PipelinesListProject", variables = { first = 50 } },
      response = { delay = opts.delay, body = body(D.nodes(nil, opts.now), opts.next_cursor) },
    },
  }
  if opts.next_cursor then
    table.insert(out, {
      request = { operation = "PipelinesListProject", variables = { after = opts.next_cursor } },
      response = { body = body(D.nodes(D.specs_page2(), opts.now)) },
    })
  end
  return out
end

--- A refresh (`ids`) answer: the pipelines of `specs`.
---@param ids integer[]
---@param specs tests.PipelineSpec[]
---@param opts? { now?: integer, repeat?: boolean }
function D.refresh_response(ids, specs, opts)
  opts = opts or {}
  return {
    ["repeat"] = opts["repeat"],
    request = {
      operation = "PipelinesListProject",
      variables = { ids = vim.tbl_map(function(id)
        return "gid://gitlab/Ci::Pipeline/" .. id
      end, ids) },
    },
    response = { body = body(D.nodes(specs, opts.now)) },
  }
end

--- The project: default branch "main".
---@param opts? { delay?: integer }
function D.project_response(opts)
  return {
    ["repeat"] = true,
    request = { operation = "ProjectGet" },
    response = {
      delay = opts and opts.delay,
      body = { data = { project = {
        id = "gid://gitlab/Project/" .. D.PROJECT_ID,
        name = "ops",
        path = "ops",
        fullPath = D.PROJECT,
        description = vim.NIL,
        webUrl = "https://" .. D.HOST .. "/" .. D.PROJECT,
        visibility = "private",
        archived = false,
        lastActivityAt = "2026-11-09T10:00:00Z",
        repository = { rootRef = "main" },
      } } },
    },
  }
end

--- The open merge requests (the merge requests mockup's: !83 to !88).
---@param opts? { delay?: integer }
function D.mrs_response(opts)
  local open = vim.tbl_filter(function(n)
    return n.state == "opened"
  end, MR.nodes())
  return {
    ["repeat"] = true,
    request = { operation = "MergeRequestsListProject", variables = { state = "opened" } },
    response = { delay = opts and opts.delay, body = MR.body(open) },
  }
end

--- Everything the view needs for one page.
---@param opts? { now?: integer, next_cursor?: string, mr_delay?: integer, project_delay?: integer }
function D.all(opts)
  opts = opts or {}
  local out = D.list_responses(opts)
  table.insert(out, D.project_response({ delay = opts.project_delay }))
  table.insert(out, D.mrs_response({ delay = opts.mr_delay }))
  return out
end

return D
