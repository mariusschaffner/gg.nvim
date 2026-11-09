-- The merge requests of the UI mockup (docs/mergerequest_table_design.png)
-- as raw GraphQL nodes, their summaries (pipeline stages + diff stats), and
-- fake-backend responses. Synthetic data: no real names, hosts or e-mails.
local mr_model = require("gg.models.merge_request")

local D = {}

D.HOST = "gitlab.example.com"
D.PROJECT = "infra/ops"
D.ME = "user-ma"

local function user(name)
  return { id = "gid://gitlab/User/" .. #name, username = name, name = "Test User 1", webPath = "/" .. name }
end

local function users(list)
  local nodes = {}
  for i, n in ipairs(list) do
    nodes[i] = user(n)
  end
  return { nodes = nodes, pageInfo = { hasNextPage = false } }
end

local function node(iid, title, draft, source, reviewers, assignee, updated, state)
  return {
    id = "gid://gitlab/MergeRequest/" .. (5000 + iid),
    iid = tostring(iid),
    title = title,
    state = state or "opened",
    draft = draft,
    sourceBranch = source,
    targetBranch = "main",
    updatedAt = updated,
    createdAt = "2026-11-01T10:00:00Z",
    webUrl = "https://" .. D.HOST .. "/" .. D.PROJECT .. "/-/merge_requests/" .. iid,
    reference = "!" .. iid,
    referenceFull = D.PROJECT .. "!" .. iid,
    author = user("user-ma"),
    assignees = users(assignee and { assignee } or {}),
    reviewers = users(reviewers),
    labels = { nodes = {}, pageInfo = { hasNextPage = false } },
    milestone = vim.NIL,
    userNotesCount = 0,
  }
end

--- Fresh raw nodes: 6 open, 2 merged, 1 closed (the mockup's counts).
function D.nodes()
  return {
    node(88, "Rotate Terraform state backend credentials", false, "feat/rotate-tf-creds", { "user-sf" }, "user-ma", "2026-11-08T12:00:00Z"),
    node(87, "WinRM over HTTPS listener role", true, "feat/winrm-https", {}, "user-ma", "2026-11-08T11:00:00Z"),
    node(86, "OCI load balancer module for edge", false, "feat/oci-edge-lb", { "user-lh", "user-sf" }, "user-ma", "2026-11-08T10:00:00Z"),
    node(85, "DNS-01 wildcard renewal via OCI DNS", false, "feat/dns01-wildcard", { "user-ma" }, "user-sf", "2026-11-08T09:00:00Z"),
    node(84, "Fix flaky weekend backup schedule", false, "fix/backup-weekend", { "user-ma" }, "user-lh", "2026-11-08T08:00:00Z"),
    node(83, "Bump Ansible collections", false, "chore/bump-collections", {}, nil, "2026-11-08T07:00:00Z"),
    node(80, "Split inventory per site", false, "feat/inventory-sites", {}, "user-ma", "2026-11-05T10:00:00Z", "merged"),
    node(79, "Pin provider versions", false, "chore/pin-providers", {}, "user-sf", "2026-11-04T10:00:00Z", "merged"),
    node(78, "Experimental bastion module", false, "spike/bastion", {}, nil, "2026-11-03T10:00:00Z", "closed"),
  }
end

--- The nodes as gg.MergeRequest models.
---@return gg.MergeRequest[]
function D.mrs()
  return vim.tbl_map(function(n)
    return mr_model.from_graphql(n, { origin = "https://" .. D.HOST, project = D.PROJECT })
  end, D.nodes())
end

local STAGES = {
  [88] = { "success", "success", "success", "manual" },
  [87] = { "success", "running", "pending", "pending" },
  [86] = { "success", "failed", "pending", "pending" },
  [85] = { "success", "success", "success", "manual" },
  [84] = { "success", "success", "success", "success" },
  [83] = { "success", "success", "success", "manual" },
  [80] = { "success" },
  [79] = { "success" },
}
local DIFF = { [88] = { 120, 34 }, [87] = { 310, 12 }, [86] = { 482, 0 }, [85] = { 96, 8 }, [84] = { 14, 6 }, [83] = { 40, 40 }, [80] = { 5, 1 }, [79] = { 2, 2 }, [78] = { 0, 0 } }
local PIPELINE_STATUS = { [87] = "RUNNING", [86] = "FAILED" }

--- The MergeRequestSummaries node of one MR (78 has no pipeline).
---@param iid integer
---@param updated string
function D.summary_node(iid, updated)
  local stages = STAGES[iid]
  local pipeline = vim.NIL
  if stages then
    local nodes = {}
    for i, s in ipairs(stages) do
      nodes[i] = { name = "stage" .. i, status = s }
    end
    pipeline = {
      id = "gid://gitlab/Ci::Pipeline/" .. (9000 + iid),
      iid = tostring(100 + iid),
      status = PIPELINE_STATUS[iid] or "SUCCESS",
      path = "/" .. D.PROJECT .. "/-/pipelines/" .. (9000 + iid),
      stages = { nodes = nodes, pageInfo = { hasNextPage = false } },
    }
  end
  local d = DIFF[iid] or { 0, 0 }
  return {
    iid = tostring(iid),
    updatedAt = updated,
    diffHeadSha = "abc" .. iid,
    headPipeline = pipeline,
    diffStatsSummary = { additions = d[1], deletions = d[2], changes = d[1] + d[2], fileCount = 1 },
  }
end

--- The summaries of the given nodes as gg.MergeRequestSummary, by IID.
---@param nodes? table[]
---@return table<integer, gg.MergeRequestSummary>
function D.summaries(nodes)
  local out = {}
  for _, n in ipairs(nodes or D.nodes()) do
    local s = mr_model.summary_from_graphql(D.summary_node(tonumber(n.iid), n.updatedAt), { origin = "https://" .. D.HOST, project = D.PROJECT })
    out[s.iid] = { updated_at = n.updatedAt, summary = s }
  end
  return out
end

--- One page of `nodes` as a GraphQL MR-list body.
function D.body(nodes, next_cursor)
  return { data = { project = { mergeRequests = { nodes = nodes, pageInfo = { hasNextPage = next_cursor ~= nil, endCursor = next_cursor or vim.NIL } } } } }
end

--- Fake-backend entries for the three list streams (one per state).
---@param nodes? table[]
---@param opts? { repeat?: boolean, delay?: integer }
function D.list_responses(nodes, opts)
  opts = opts or {}
  nodes = nodes or D.nodes()
  local out = {}
  for _, state in ipairs({ "opened", "merged", "closed" }) do
    local part = vim.tbl_filter(function(n)
      return n.state == state
    end, nodes)
    table.insert(out, {
      ["repeat"] = opts["repeat"],
      request = { operation = "MergeRequestsListProject", variables = { state = state } },
      response = { delay = opts.delay, body = D.body(part) },
    })
  end
  return out
end

--- A repeating fake-backend entry answering every summaries request with
--- all of `nodes` (the view keeps only the IIDs it asked for). IIDs in
--- `opts.nil_stats` get GitLab's "no line counts" value (0 / 0, 0 files).
---@param nodes? table[]
---@param opts? { delay?: integer, nil_stats?: table<integer, boolean> }
function D.summaries_response(nodes, opts)
  local list = {}
  for _, n in ipairs(nodes or D.nodes()) do
    local s = D.summary_node(tonumber(n.iid), n.updatedAt)
    if opts and opts.nil_stats and opts.nil_stats[tonumber(n.iid)] then
      s.diffStatsSummary = { additions = 0, deletions = 0, changes = 0, fileCount = 0 }
    end
    table.insert(list, s)
  end
  return {
    ["repeat"] = true,
    request = { operation = "MergeRequestSummaries" },
    response = { delay = opts and opts.delay, body = { data = { project = { mergeRequests = { nodes = list } } } } },
  }
end

--- A REST `/diffs` page for MR `iid`: two files, 3 additions and 1 deletion.
---@param iid integer
---@param opts? { status?: integer }
function D.diffs_response(iid, opts)
  local path = ("/api/v4/projects/%s/merge_requests/%d/diffs"):format(D.PROJECT:gsub("/", "%%2F"), iid)
  if opts and opts.status then
    return { request = { method = "GET", path = path }, response = { status = opts.status, body = { message = "boom" } } }
  end
  local function file(name, diff)
    return { old_path = name, new_path = name, a_mode = "100644", b_mode = "100644", diff = diff, new_file = false, renamed_file = false, deleted_file = false }
  end
  return {
    request = { method = "GET", path = path },
    response = {
      headers = { ["x-next-page"] = "" },
      body = { file("a.tf", "@@ -1 +1,2 @@\n-x\n+y\n+z\n"), file("b.tf", "@@ -0,0 +1 @@\n+w\n") },
    },
  }
end

--- The signed-in user.
function D.me_response()
  return {
    ["repeat"] = true,
    request = { operation = "UserCurrent" },
    response = { body = { data = { currentUser = user(D.ME) } } },
  }
end

--- Everything the view needs: lists, summaries, the current user.
function D.all(opts)
  local out = D.list_responses(nil, { ["repeat"] = true })
  table.insert(out, D.summaries_response(nil, opts))
  table.insert(out, D.me_response())
  return out
end

return D
