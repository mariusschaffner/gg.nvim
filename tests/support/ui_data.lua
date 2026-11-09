-- The issues of the UI mockup (docs/issue_table_design.png) as raw GraphQL
-- nodes, plus helpers to turn them into models or a fake-backend response.
-- Synthetic data: no real names, hosts or e-mails.
local issue_model = require("gg.models.issue")

local D = {}

D.HOST = "gitlab.example.com"
D.PROJECT = "infra/ops"
D.TODAY = { year = 2026, month = 11, day = 8 }

local COLORS = {
  security = "#f7768e",
  terraform = "#bb9af7",
  ansible = "#7dcfff",
  windows = "#7aa2f7",
  monitoring = "#e0af68",
  bug = "#f7768e",
  docs = "#9ece6a",
  oci = "#ff9e64",
  network = "#7dcfff",
  dns = "#73daca",
  backup = "#7aa2f7",
  chore = "#a9b1d6",
}

D.MILESTONES = {
  m11 = { id = "gid://gitlab/Milestone/11", iid = "1", title = "2026.11 Patch cycle", state = "active", dueDate = "2026-11-20", startDate = vim.NIL, webPath = "/infra/ops/-/milestones/1", stats = { totalIssuesCount = 6, closedIssuesCount = 2 } },
  m12 = { id = "gid://gitlab/Milestone/12", iid = "2", title = "2026.12 Cloud migration", state = "active", dueDate = "2026-12-18", startDate = vim.NIL, webPath = "/infra/ops/-/milestones/2", stats = { totalIssuesCount = 4, closedIssuesCount = 1 } },
}

local function node(iid, title, labels, user, ms, due, updated, state)
  local label_nodes = {}
  for i, name in ipairs(labels) do
    label_nodes[i] = { id = "gid://gitlab/ProjectLabel/" .. i, title = name, color = COLORS[name] or "#888888", textColor = "#FFFFFF", description = vim.NIL }
  end
  return {
    id = "gid://gitlab/Issue/" .. (1000 + iid),
    iid = tostring(iid),
    title = title,
    state = state or "opened",
    type = "ISSUE",
    confidential = false,
    dueDate = due or vim.NIL,
    webUrl = ("https://%s/%s/-/issues/%d"):format(D.HOST, D.PROJECT, iid),
    userNotesCount = 0,
    createdAt = "2026-10-01T09:00:00Z",
    updatedAt = updated or "2026-11-01T09:00:00Z",
    closedAt = vim.NIL,
    reference = "#" .. iid,
    referenceFull = D.PROJECT .. "#" .. iid,
    author = { id = "gid://gitlab/User/1", username = "user-1", name = "User One", avatarUrl = vim.NIL, webUrl = vim.NIL, state = "active" },
    assignees = {
      nodes = user and { { id = "gid://gitlab/User/2", username = user, name = "User", avatarUrl = vim.NIL, webUrl = vim.NIL, state = "active" } } or {},
      pageInfo = { hasNextPage = false },
    },
    labels = { nodes = label_nodes, pageInfo = { hasNextPage = false } },
    milestone = ms and D.MILESTONES[ms] or vim.NIL,
  }
end

--- Fresh raw nodes (9 open, 3 closed, like the mockup's counts).
function D.nodes()
  return {
    node(220, "Flaky backup job on weekend window", { "bug", "backup" }, "user-lh", nil, nil, "2026-11-08T10:00:00Z"),
    node(198, "Clean up unused container registry tags", { "chore" }, nil, nil, nil, "2026-10-25T10:00:00Z"),
    node(214, "Rotate Terraform state backend credentials", { "security", "terraform" }, "user-ma", "m11", "2026-11-12"),
    node(211, "WinRM over HTTPS for newly joined hosts", { "ansible", "windows" }, "user-ma", "m11", "2026-11-06"),
    node(209, "Monitoring sensor for pending-reboot state", { "monitoring" }, "user-lh", "m11", "2026-11-18"),
    node(205, "Document patch-window rollback procedure", { "docs" }, nil, "m11", "2026-11-19"),
    node(219, "Migrate nginx gateway to OCI load balancer", { "oci", "network" }, "user-ma", "m12", "2026-12-05"),
    node(218, "Wildcard cert renewal via DNS-01 challenge", { "oci", "dns" }, "user-sf", "m12", "2026-12-08"),
    node(216, "Terraform module for object storage buckets", { "terraform" }, "user-ma", "m12", "2026-12-12"),
    node(201, "Patch hypervisors", { "chore" }, "user-ma", "m11", "2026-11-02", nil, "closed"),
    node(202, "Rotate SSH host keys", { "security" }, nil, "m11", "2026-11-03", nil, "closed"),
    node(190, "Retire legacy cron host", { "chore" }, nil, nil, nil, "2026-09-01T10:00:00Z", "closed"),
  }
end

--- The nodes as gg.Issue models.
---@return gg.Issue[]
function D.issues()
  return vim.tbl_map(function(n)
    return issue_model.from_graphql(n, { origin = "https://" .. D.HOST, project = D.PROJECT })
  end, D.nodes())
end

--- A fake-backend entry answering the project issue list with `nodes`.
function D.response(nodes, opts)
  opts = opts or {}
  return {
    ["repeat"] = opts["repeat"],
    request = { operation = "IssuesListProject" },
    response = opts.response or { body = { data = { project = { issues = { nodes = nodes or D.nodes(), pageInfo = { hasNextPage = false, endCursor = vim.NIL } } } } } },
  }
end

return D
