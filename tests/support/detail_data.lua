-- Synthetic API responses for the detail views (issue, milestone, merge
-- request, pipeline). No real names, hosts or e-mails.
local D = require("tests.support.ui_data")

local X = {}

X.HOST = D.HOST
X.PROJECT = D.PROJECT
X.ENC = "infra%2Fops"
X.NOW = "2026-11-10T12:00:00Z"
X.TODAY = { year = 2026, month = 11, day = 10 }

function X.user(n, name)
  return { id = "gid://gitlab/User/" .. n, username = "user-" .. n, name = name or ("User " .. n), avatarUrl = vim.NIL, webUrl = vim.NIL, state = "active" }
end

function X.rest_user(n, name)
  return { id = n, username = "user-" .. n, name = name or ("User " .. n), state = "active" }
end

X.DESCRIPTION = table.concat({
  "Rotate the credentials of the state backend.",
  "",
  "## Acceptance",
  "- [x] new key in the vault",
  "- [ ] old key revoked",
  "",
  "See #12 and the runbook.",
}, "\n")

-- the issue node of IssueGet (#214 of the issues table, with a description)
function X.issue_node()
  local node = D.nodes()[3]
  node.description = X.DESCRIPTION
  node.subscribed = false
  node.userNotesCount = 2
  return node
end

function X.issue_get(node)
  return {
    request = { operation = "IssueGet", variables = { iid = "214" } },
    response = { body = { data = { project = { issue = node or X.issue_node() } } } },
  }
end

function X.dates(start, due)
  return {
    request = { operation = "WorkItemDates" },
    response = {
      body = {
        data = {
          namespace = {
            workItem = {
              id = "gid://gitlab/WorkItem/9214",
              iid = "214",
              widgets = { { type = "START_AND_DUE_DATE", startDate = start or vim.NIL, dueDate = due or vim.NIL } },
            },
          },
        },
      },
    },
  }
end

function X.branches(names)
  local body = {}
  for _, n in ipairs(names) do
    table.insert(body, { name = n, default = false, protected = false, merged = false, commit = { id = "abc", title = "wip", committed_date = X.NOW } })
  end
  return {
    request = { method = "GET", path = "/api/v4/projects/" .. X.ENC .. "/repository/branches" },
    response = { body = body },
  }
end

function X.rest_mr(iid, title, state, extra)
  local mr = {
    id = 5000 + iid,
    iid = iid,
    project_id = 7,
    title = title,
    state = state or "opened",
    draft = false,
    source_branch = "214-rotate",
    target_branch = "main",
    author = X.rest_user(1, "Ann Example"),
    assignees = {},
    reviewers = {},
    labels = {},
    web_url = ("https://%s/%s/-/merge_requests/%d"):format(X.HOST, X.PROJECT, iid),
    references = { short = "!" .. iid, full = X.PROJECT .. "!" .. iid },
    created_at = "2026-11-01T09:00:00Z",
    updated_at = "2026-11-09T09:00:00Z",
    user_notes_count = 0,
  }
  for k, v in pairs(extra or {}) do
    mr[k] = v
  end
  return mr
end

function X.related_mrs(mrs, iid)
  return {
    request = { method = "GET", path = ("/api/v4/projects/%s/issues/%d/related_merge_requests"):format(X.ENC, iid or 214) },
    response = { body = mrs },
  }
end

function X.note(id, body, at, author, extra)
  local n = {
    id = "gid://gitlab/Note/" .. id,
    body = body,
    system = false,
    systemNoteIconName = vim.NIL,
    systemNoteMetadata = vim.NIL,
    internal = false,
    createdAt = at,
    updatedAt = at,
    url = vim.NIL,
    resolvable = false,
    resolved = false,
    author = author or X.user(1, "Ann Example"),
    discussion = { id = "gid://gitlab/Discussion/d" .. id },
    position = vim.NIL,
    awardEmoji = { nodes = {}, pageInfo = { hasNextPage = false } },
  }
  for k, v in pairs(extra or {}) do
    n[k] = v
  end
  return n
end

function X.discussion(id, notes, extra)
  local d = {
    id = "gid://gitlab/Discussion/" .. id,
    resolvable = false,
    resolved = false,
    resolvedAt = vim.NIL,
    resolvedBy = vim.NIL,
    notes = { nodes = notes, pageInfo = { hasNextPage = false } },
  }
  for k, v in pairs(extra or {}) do
    d[k] = v
  end
  return d
end

-- two comments in one thread and a label event
function X.issue_discussions()
  return {
    request = { operation = "IssueDiscussions" },
    response = {
      body = {
        data = {
          project = {
            issue = {
              discussions = {
                nodes = {
                  X.discussion("s1", { X.note(1, "added ~docs label", "2026-11-09T08:00:00Z", nil, { system = true, systemNoteIconName = "label" }) }),
                  X.discussion("t1", {
                    X.note(2, "Which key do we rotate first?", "2026-11-10T09:00:00Z"),
                    X.note(3, "The state backend one.", "2026-11-10T09:30:00Z", X.user(2, "Bob Sample")),
                  }),
                },
                pageInfo = { hasNextPage = false, endCursor = vim.NIL },
              },
            },
          },
        },
      },
    },
  }
end

function X.current_user()
  return {
    ["repeat"] = true,
    request = { operation = "UserCurrent" },
    response = { body = { data = { currentUser = X.user(1, "Ann Example") } } },
  }
end

-- everything the issue view asks for
function X.issue_responses(opts)
  opts = opts or {}
  return {
    X.issue_get(),
    X.dates("2026-11-01", "2026-11-14"),
    X.branches(opts.branches or { "214-rotate-credentials" }),
    X.related_mrs(opts.mrs or { X.rest_mr(88, "Rotate Terraform state backend credentials") }),
    X.issue_discussions(),
    X.current_user(),
  }
end

-- the milestone %11 of the issues table, with dates and a description
function X.milestone_node(extra)
  local m = {
    id = "gid://gitlab/Milestone/11",
    iid = "1",
    title = "2026.11 Patch cycle",
    description = table.concat({ "Patch everything.", "", "- [x] hypervisors", "- [ ] hosts" }, string.char(10)),
    state = "active",
    startDate = "2026-11-02",
    dueDate = "2026-11-20",
    expired = false,
    webPath = "/infra/ops/-/milestones/1",
    stats = { totalIssuesCount = 6, closedIssuesCount = 2 },
    createdAt = "2026-10-20T09:00:00Z",
    updatedAt = "2026-11-09T12:00:00Z",
    project = { fullPath = X.PROJECT },
    group = vim.NIL,
  }
  for k, v in pairs(extra or {}) do
    m[k] = v
  end
  return m
end

function X.milestone_get(node)
  return {
    request = { operation = "MilestoneGet" },
    response = { body = { data = { milestone = node or X.milestone_node() } } },
  }
end

-- the issues of %11, two of them labelled WF:Doing
function X.milestone_issues()
  local nodes = vim.tbl_filter(function(n)
    return n.milestone ~= vim.NIL and n.milestone.title == "2026.11 Patch cycle"
  end, D.nodes())
  for _, n in ipairs(nodes) do
    if n.iid == "214" or n.iid == "209" then
      table.insert(n.labels.nodes, { id = "gid://gitlab/ProjectLabel/99", title = "WF:Doing", color = "#8a2be2", textColor = "#FFFFFF", description = vim.NIL })
    end
  end
  return {
    request = { operation = "IssuesListProject" },
    response = { body = D.body(nodes) },
  }
end

function X.milestone_mrs()
  local MR = require("tests.support.mr_data")
  local nodes = { MR.nodes()[1], MR.nodes()[2] }
  return {
    request = { operation = "MergeRequestsListProject" },
    response = { body = MR.body(nodes) },
  }
end

function X.milestone_responses()
  local MR = require("tests.support.mr_data")
  return { X.milestone_get(), X.milestone_issues(), X.milestone_mrs(), MR.summaries_response() }
end

-- a recorded fixture's body, served for `request` (any variables)
function X.replay(file, request, opts)
  local H = require("tests.helpers")
  local list = vim.json.decode(H.read("tests/fixtures/" .. file), { luanil = { object = false, array = false } })
  if list.request then
    list = { list }
  end
  local i = opts and opts.index or 1
  return { ["repeat"] = opts and opts["repeat"], request = request, response = { body = list[i].response.body } }
end

X.MR_IID = 88

-- a merge request that closes #214 and #211, with a WF label on #214
function X.mr_get(over, opts)
  local e = X.replay("graphql/merge_requests/get.json", { operation = "MergeRequestGet" }, opts)
  local mr = e.response.body.data.project.mergeRequest
  for k, v in pairs(over or {}) do
    mr[k] = v
  end
  mr.iid = tostring(X.MR_IID)
  mr.title = "Rotate Terraform state backend credentials"
  mr.description = table.concat({ "Rotates the keys.", "", "Closes #214 and #211", "", "Thanks." }, string.char(10))
  mr.updatedAt = "2026-11-10T09:00:00Z"
  -- the recorded body belongs to another project; this one is ours
  mr.reference = "!" .. X.MR_IID
  mr.referenceFull = X.PROJECT .. "!" .. X.MR_IID
  mr.webUrl = ("https://%s/%s/-/merge_requests/%d"):format(X.HOST, X.PROJECT, X.MR_IID)
  for k, v in pairs(over or {}) do
    mr[k] = v
  end
  return e
end

-- an open merge request !88 with everything the view loads; checks and
-- reviewers repeat (actions reload them)
function X.open_mr_responses()
  local out = X.mr_responses()
  out[1] = X.mr_get({ state = "opened", mergedAt = vim.NIL }, { ["repeat"] = true })
  out[2]["repeat"] = true
  out[3]["repeat"] = true
  return out
end

-- PUT / POST on merge request !88 (`suffix` e.g. "/merge"), answered with a
-- REST merge request
function X.mr_write(method, suffix, body, over, opts)
  return {
    request = { method = method, path = ("/api/v4/projects/%s/merge_requests/%d%s"):format(X.ENC, X.MR_IID, suffix or ""), body_contains = body },
    response = opts and opts.status and { status = opts.status, body = { message = opts.message or "boom" } }
      or { body = X.rest_mr(X.MR_IID, "Rotate Terraform state backend credentials", (over or {}).state or "opened", over) },
  }
end

-- PUT on milestone 11, answered with a REST milestone
function X.milestone_put(body, over)
  local m = { id = 11, iid = 1, project_id = 7, title = "2026.11 Patch cycle", description = "Patch everything.", state = "active", start_date = "2026-11-02", due_date = "2026-11-20", updated_at = "2026-11-10T11:00:00Z", created_at = "2026-10-20T09:00:00Z", web_url = "https://gitlab.example.com/infra/ops/-/milestones/1" }
  for k, v in pairs(over or {}) do
    m[k] = v
  end
  return {
    request = { method = "PUT", path = ("/api/v4/projects/%s/milestones/11"):format(X.ENC), body_contains = body },
    response = { body = m },
  }
end

-- the recorded commits, as one page
function X.mr_commits()
  local e = X.replay("graphql/mr_changes/commits.json", { operation = "MrCommits" }, { index = 1 })
  e.response.body.data.project.mergeRequest.commits.pageInfo = { hasNextPage = false, endCursor = vim.NIL }
  return e
end

function X.mr_responses()
  local ui = require("tests.support.ui_data")
  local closes = vim.tbl_filter(function(n)
    return n.iid == "214" or n.iid == "211"
  end, ui.nodes())
  table.insert(closes[1].labels.nodes, { id = "gid://gitlab/ProjectLabel/98", title = "WF:Review", color = "#00aa00", textColor = "#FFFFFF", description = vim.NIL })
  return {
    X.mr_get(),
    X.replay("graphql/mr_checks/full.json", { operation = "MrChecksFull" }),
    X.replay("graphql/reviews/reviewers.json", { operation = "MrReviewers" }),
    X.replay("graphql/mr_changes/stats.json", { operation = "MrDiffStats" }),
    X.mr_commits(),
    { request = { operation = "IssuesListProject" }, response = { body = ui.body(closes) } },
    X.replay("graphql/pipelines/list_mr.json", { operation = "PipelinesListMr" }, { ["repeat"] = true }),
    X.replay("rest/notes/mr_discussions.json", { method = "GET", path = ("/api/v4/projects/%s/merge_requests/%d/discussions"):format(X.ENC, X.MR_IID) }),
    X.current_user(),
    { ["repeat"] = true, request = { operation = "ProjectGet" }, response = { body = { data = { project = vim.NIL } } } },
  }
end

-- a running pipeline: build (passed), test (running + allowed failure),
-- deploy (manual)
X.PIPELINE_ID = 4821

function X.job(id, name, stage, status, extra)
  local j = {
    id = "gid://gitlab/Ci::Build/" .. id,
    name = name,
    status = status:upper(),
    allowFailure = false,
    manualJob = false,
    playable = false,
    retryable = false,
    cancelable = false,
    duration = vim.NIL,
    queuedDuration = vim.NIL,
    startedAt = vim.NIL,
    finishedAt = vim.NIL,
    createdAt = "2026-11-10T11:50:00Z",
    webPath = "/infra/ops/-/jobs/" .. id,
    refName = "main",
    shortSha = "a1f3c9e0",
    stage = { name = stage },
  }
  for k, v in pairs(extra or {}) do
    j[k] = v
  end
  return j
end

local function stage(name, status, jobs)
  local groups = {}
  for _, j in ipairs(jobs) do
    table.insert(groups, { name = j.name, size = 1, jobs = { nodes = { j }, pageInfo = { hasNextPage = false } } })
  end
  return { name = name, status = status, groups = { nodes = groups, pageInfo = { hasNextPage = false } } }
end

function X.pipeline_node(over)
  over = over or {}
  local run_status = over.test_status or "running"
  local stages = {
    stage("build", "success", {
      X.job(101, "build-agent", "build", "success", { duration = 62, startedAt = "2026-11-10T11:51:00Z", finishedAt = "2026-11-10T11:52:02Z" }),
    }),
    stage("test", run_status, {
      X.job(102, "molecule", "test", run_status, run_status == "running" and { startedAt = "2026-11-10T11:57:46Z" } or { startedAt = "2026-11-10T11:57:46Z", finishedAt = "2026-11-10T11:59:00Z", duration = 74 }),
      X.job(103, "lint", "test", "failed", { allowFailure = true, duration = 12, startedAt = "2026-11-10T11:53:00Z", finishedAt = "2026-11-10T11:53:12Z" }),
    }),
    stage("deploy", "manual", { X.job(104, "deploy-prod", "deploy", "manual", { manualJob = true, playable = true }) }),
  }
  local summary = {}
  for _, s in ipairs(stages) do
    table.insert(summary, { name = s.name, status = s.status })
  end
  return {
    id = "gid://gitlab/Ci::Pipeline/" .. X.PIPELINE_ID,
    iid = "21",
    status = (over.status or "running"):upper(),
    ref = "main",
    sha = "a1f3c9e0a1f3c9e0a1f3c9e0a1f3c9e0a1f3c9e0",
    shortSha = "a1f3c9e0",
    source = "push",
    createdAt = "2026-11-10T11:50:00Z",
    startedAt = "2026-11-10T11:51:00Z",
    finishedAt = vim.NIL,
    duration = vim.NIL,
    queuedDuration = vim.NIL,
    path = "/infra/ops/-/pipelines/" .. X.PIPELINE_ID,
    totalJobs = 4,
    retryable = false,
    cancelable = true,
    warnings = false,
    user = X.user(1, "Ann Example"),
    commit = { title = "Add HTTPS listener task" },
    stages = { nodes = summary, pageInfo = { hasNextPage = false } },
    mergeRequest = vim.NIL,
    graph = { nodes = stages, pageInfo = { hasNextPage = false } },
  }
end

function X.pipeline_graph(over, opts)
  return {
    ["repeat"] = opts and opts["repeat"],
    request = { operation = "PipelineGraph" },
    response = { body = { data = { project = { pipeline = X.pipeline_node(over) } } } },
  }
end

X.LOG = table.concat({
  "\27[0KRunning with gitlab-runner 18.5.0",
  "\27[0Ksection_start:1762775866:prepare_script\r\27[0KPreparing environment",
  "Running on runner-abc",
  "section_end:1762775869:prepare_script\r\27[0K",
  "\27[32;1m$ molecule test\27[0;m",
  "progress 10%\rprogress 100%",
  "ERROR: something broke",
  "",
}, string.char(10))

function X.trace(job_id, body, opts)
  opts = opts or {}
  return {
    ["repeat"] = opts["repeat"],
    request = { method = "GET", path = ("/api/v4/projects/%s/jobs/%d/trace"):format(X.ENC, job_id), query_contains = {} },
    response = { status = opts.status or 200, body = body, headers = opts.headers or { ["Content-Type"] = "text/plain" } },
  }
end

-- Writes ---------------------------------------------------------------------

-- a REST issue (the answer of PUT /issues/:iid) for #214
function X.rest_issue(over)
  local i = {
    id = 1214,
    iid = 214,
    project_id = 7,
    title = "Rotate Terraform state backend credentials",
    description = X.DESCRIPTION,
    state = "opened",
    created_at = "2026-10-01T09:00:00Z",
    updated_at = "2026-11-10T11:00:00Z",
    labels = { "security", "terraform" },
    milestone = { id = 11, iid = 1, title = "2026.11 Patch cycle", state = "active", due_date = "2026-11-20" },
    assignees = { X.rest_user(2, "User") },
    author = X.rest_user(1, "User One"),
    type = "ISSUE",
    issue_type = "issue",
    user_notes_count = 2,
    due_date = "2026-11-12",
    confidential = false,
    web_url = ("https://%s/%s/-/issues/214"):format(X.HOST, X.PROJECT),
    references = { short = "#214", relative = "#214", full = X.PROJECT .. "#214" },
  }
  for k, v in pairs(over or {}) do
    i[k] = v
  end
  return i
end

-- PUT /issues/214 answered with `over` applied; `body` must be in the request
function X.issue_put(body, over, opts)
  return {
    ["repeat"] = opts and opts["repeat"],
    request = { method = "PUT", path = ("/api/v4/projects/%s/issues/214"):format(X.ENC), body_contains = body },
    response = opts and opts.status and { status = opts.status, body = { message = "boom" } } or { body = X.rest_issue(over) },
  }
end

function X.members()
  local nodes = {}
  for n, name in pairs({ [1] = "Ann Example", [2] = "Bob Sample", [3] = "Cid Third" }) do
    local u = X.user(n, name)
    table.insert(nodes, { id = "gid://gitlab/ProjectMember/" .. n, accessLevel = { integerValue = 30, stringValue = "DEVELOPER" }, user = u })
  end
  table.sort(nodes, function(a, b)
    return a.id < b.id
  end)
  return {
    ["repeat"] = true,
    request = { operation = "ProjectMembersList" },
    response = { body = { data = { project = { projectMembers = { nodes = nodes, pageInfo = { hasNextPage = false, endCursor = vim.NIL } } } } } },
  }
end

function X.labels_list()
  local nodes = {}
  for i, name in ipairs({ "security", "terraform", "docs", "WF:Doing" }) do
    table.insert(nodes, { id = "gid://gitlab/ProjectLabel/" .. i, title = name, color = "#888888", textColor = "#FFFFFF", description = vim.NIL })
  end
  return {
    ["repeat"] = true,
    request = { operation = "LabelsList" },
    response = { body = { data = { project = { labels = { nodes = nodes, pageInfo = { hasNextPage = false, endCursor = vim.NIL } } } } } },
  }
end

function X.milestones_list()
  return {
    ["repeat"] = true,
    request = { operation = "MilestonesList" },
    response = {
      body = {
        data = {
          project = {
            milestones = {
              nodes = { X.milestone_node(), X.milestone_node({ id = "gid://gitlab/Milestone/12", iid = "2", title = "2026.12 Cloud migration" }) },
              pageInfo = { hasNextPage = false, endCursor = vim.NIL },
            },
          },
        },
      },
    },
  }
end

function X.dates_update(start, due)
  return {
    request = { operation = "WorkItemUpdateDates" },
    response = {
      body = {
        data = {
          workItemUpdate = {
            errors = {},
            workItem = { id = "gid://gitlab/WorkItem/9214", iid = "214", widgets = { { type = "START_AND_DUE_DATE", startDate = start or vim.NIL, dueDate = due or vim.NIL } } },
          },
        },
      },
    },
  }
end

return X
