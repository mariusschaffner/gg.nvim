-- New merge request: branch defaults, the title and Closes prefill, the
-- branch picker, and the checks before sending. Also the git helpers.
local H = require("tests.helpers")
local MR = require("tests.support.mr_data")
local P = require("tests.support.create_data")
local X = require("tests.support.detail_data")
local project = require("gg.ui.project")
local ref_picker = require("gg.ui.create.ref_picker")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = { pre_case = P.pre_case, post_case = P.post_case } })

local API = "/api/v4/projects/" .. X.ENC
local BRANCHES = API .. "/repository/branches"

local function branch(name, default)
  return { name = name, default = default or false, protected = false, merged = false, commit = { id = "1a2b3c4d5e6f", title = "tidy up " .. name, committed_date = X.NOW } }
end

-- the default branch ("main") and the signed-in user
local function base(extra)
  local out = {
    X.replay("graphql/projects/get.json", { operation = "ProjectGet" }, { ["repeat"] = true }),
    X.current_user(),
  }
  return vim.list_extend(out, extra or {})
end

local function no_open_mr()
  return { request = { operation = "MergeRequestsListProject" }, response = { body = MR.body({}) } }
end

local function settled(p)
  H.wait_for(function()
    return p:field("target") ~= nil and p.data.user ~= nil
  end)
  H.flush(5)
end

-- the ref picker's list window, once it shows `n` lines
local function ref_list(n)
  local found
  H.wait_for(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "gg_ui_ref_list" then
        found = w
      end
    end
    return found ~= nil and #P.lines(vim.api.nvim_win_get_buf(found)) == n and P.lines(vim.api.nvim_win_get_buf(found))[1] ~= " Loading…"
  end)
  return found
end

local function posts(fake)
  return vim.tbl_filter(function(r)
    return r.method == "POST" and r.path == API .. "/merge_requests"
  end, fake:requests())
end

T["defaults: source, the default branch as target, Merge … into …"] = function()
  local p = P.open("merge_request", { source_branch = "test" }, base())
  local m = p.group.members
  settled(p)
  eq(P.title(m.title.win), " ＋ New merge request ")
  eq(vim.api.nvim_win_get_config(m.title.win).title[1][2], "GitlabCreateMR")
  eq(P.title(m.field_source.win), " [gB] Source ")
  eq(P.title(m.field_target.win), " [gd] Target ")
  eq(P.lines(m.field_source.buf), { "⎇ test" })
  eq(P.lines(m.field_target.buf), { "⎇ main" })
  eq(P.lines(m.title.buf), { "Merge test into main" })
  eq(P.lines(m.body.buf), { "" })
  eq(P.title(m.body.win):find(" Merge Request ─", 1, true) ~= nil, true)
  eq(p:dirty(), false) -- defaults are not changes
  local hl = vim.api.nvim_buf_get_extmarks(m.field_source.buf, p.ns, 0, -1, { details = true })[1][4].hl_group
  eq(hl, "GitlabBranchSource")
end

T["the current git branch is the default source"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.system({ "git", "-C", dir, "init", "-q", "-b", "feature-x" })
  local p = P.open("merge_request", { cwd = dir }, base())
  H.wait_for(function()
    return p:field("source") ~= nil
  end, 5000)
  eq(p:field("source"), "feature-x")
  vim.fn.delete(dir, "rf")
end

T["a branch named after an issue: its title and Closes #N"] = function()
  local p = P.open("merge_request", { source_branch = "214-rotate-credentials" }, base({ X.issue_get() }))
  local m = p.group.members
  settled(p)
  H.wait_for(function()
    return P.lines(m.title.buf)[1] == "Rotate Terraform state backend credentials"
  end)
  eq(P.lines(m.body.buf), { "Closes #214" })
  eq(p:dirty(), false)
end

T["a number that is no issue keeps the generated title"] = function()
  local p = P.open("merge_request", { source_branch = "2026-plan" }, base({
    { request = { operation = "IssueGet" }, response = { body = { data = { project = { issue = vim.NIL } } } } },
  }))
  settled(p)
  H.flush(20)
  eq(P.lines(p.group.members.title.buf), { "Merge 2026-plan into main" })
  eq(P.lines(p.group.members.body.buf), { "Closes #2026" })
end

T["gB / gd pick a branch from a filtered list; the generated title follows"] = function()
  local p, _, fake = P.open("merge_request", { source_branch = "test" }, base({
    { ["repeat"] = true, request = { method = "GET", path = BRANCHES, query_contains = { search = "dev" } }, response = { body = { branch("develop") } } },
    { ["repeat"] = true, request = { method = "GET", path = BRANCHES }, response = { body = { branch("develop"), branch("main", true), branch("test") } } },
  }))
  local m = p.group.members
  settled(p)
  ref_picker.MAX_ROWS = 10
  P.keys("gd")
  local list_win = ref_list(3)
  local prompt_win = vim.api.nvim_get_current_win()
  eq(vim.bo[vim.api.nvim_win_get_buf(prompt_win)].filetype, "gg_ui_ref_prompt")
  eq(P.title(prompt_win), " Target branch ")
  -- below the target field, as wide as it
  local pc, fc = vim.api.nvim_win_get_config(prompt_win), vim.api.nvim_win_get_config(m.field_target.win)
  eq({ pc.row, pc.col, pc.width }, { fc.row + 3, fc.col, fc.width })
  -- the default branch first, then by name, with the commit dimmed
  eq(P.lines(vim.api.nvim_win_get_buf(list_win)), {
    " ⎇ main  1a2b3c4d  tidy up main",
    " ⎇ develop  1a2b3c4d  tidy up develop",
    " ⎇ test  1a2b3c4d  tidy up test",
  })
  -- typing filters on GitLab
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "dev" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = 0 })
  H.wait_for(function()
    return #P.lines(vim.api.nvim_win_get_buf(list_win)) == 1
  end)
  eq(fake:last().query.search, "dev")
  P.keys("<CR>")
  eq(P.lines(m.field_target.buf), { "⎇ develop" })
  eq(P.lines(m.title.buf), { "Merge test into develop" })
  eq(vim.api.nvim_win_is_valid(list_win), false)
  eq(vim.api.nvim_get_current_win(), m.field_target.win)
  eq(p.closed, false)
  eq(p:dirty(), true)
  -- a title of your own is kept when a branch changes
  vim.api.nvim_buf_set_lines(m.title.buf, 0, -1, false, { "feat: my own" })
  P.keys("gB")
  H.wait_for(function()
    return vim.bo[vim.api.nvim_get_current_buf()].filetype == "gg_ui_ref_prompt"
  end)
  eq(P.title(vim.api.nvim_get_current_win()), " Source branch ")
  ref_list(3)
  P.keys("<C-n>")
  P.keys("<CR>")
  eq(p:field("source"), "develop")
  eq(P.lines(m.title.buf), { "feat: my own" })
  -- Esc closes the list and keeps the value
  P.keys("gB")
  H.wait_for(function()
    return vim.bo[vim.api.nvim_get_current_buf()].filetype == "gg_ui_ref_prompt"
  end)
  P.keys("<Esc>")
  eq({ p:field("source"), p.closed }, { "develop", false })
end

T["source and target must differ"] = function()
  local p, _, fake = P.open("merge_request", { source_branch = "main" }, base())
  settled(p)
  local before = #fake:requests()
  P.keys("<C-s>")
  eq(#fake:requests(), before)
  eq(P.diagnostics(p, p.group.members.field_target.buf), { "Source and target branch are the same" })
  eq(P.footer(p.group.members.body.win):find("Source and target branch are the same", 1, true) ~= nil, true)
end

T["<C-s> checks the branch and existing merge requests, creates, and opens it"] = function()
  local responses = base(X.open_mr_responses())
  vim.list_extend(responses, {
    { request = { method = "GET", path = BRANCHES .. "/test" }, response = { body = branch("test") } },
    {
      request = { method = "POST", path = API .. "/merge_requests" },
      response = { status = 201, body = X.rest_mr(88, "Merge test into main") },
    },
  })
  -- the list of open merge requests for the branch comes first: none
  table.insert(responses, 1, no_open_mr())
  local p, s, fake = P.open("merge_request", { source_branch = "test" }, responses)
  settled(p)
  vim.api.nvim_buf_set_lines(p.body_float.buf, 0, -1, false, { "## What changed", "- things" })
  P.keys("<C-s>")
  eq(P.footer(p.group.members.body.win):find(" checking… ─", 1, true) ~= nil, true)
  H.wait_for(function()
    return p.closed and s:depth() == 2 and s:top().group.members.header ~= nil
  end)
  local post = posts(fake)
  eq(#post, 1)
  eq(post[1].json, {
    source_branch = "test",
    target_branch = "main",
    title = "Merge test into main",
    description = "## What changed\n- things",
    assignee_ids = { 1 },
  })
  -- asked for open merge requests of exactly this branch
  local asked
  for _, r in ipairs(fake:requests()) do
    if r.operation == "MergeRequestsListProject" and r.variables.sourceBranches then
      asked = { r.variables.sourceBranches, r.variables.state }
    end
  end
  eq(asked, { { "test" }, "opened" })
  eq(s.screens[1].dirty, { merge_request = true, issue = true })
end

T["a branch that is not on GitLab: offer to push; no keeps the popup"] = function()
  local p, s, fake = P.open("merge_request", { source_branch = "local-only" }, base({
    { ["repeat"] = true, request = { method = "GET", path = BRANCHES .. "/local-only" }, response = { status = 404, body = { message = "404 Branch Not Found" } } },
  }))
  settled(p)
  local asked
  vim.ui.input = function(opts, cb)
    asked = opts.prompt
    cb("n")
  end
  P.keys("<C-s>")
  H.wait_for(function()
    return p.state == "error"
  end)
  eq(asked, "Branch local-only is not on GitLab. Push it (git push -u origin local-only)? [y/N]: ")
  eq({ p.closed, s:depth(), #posts(fake) }, { false, 2, 0 })
  eq(P.diagnostics(p, p.group.members.field_source.buf), { "Branch local-only is not on GitLab" })
  eq(vim.bo[p.body_float.buf].modifiable, true)
  -- yes: git push runs; here it fails (no repository), which is reported
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  p.preset.cwd = dir
  vim.ui.input = function(_, cb)
    cb("y")
  end
  P.keys("<C-s>")
  H.wait_for(function()
    return p.state == "error" and P.notes[#P.notes][1]:find("git push failed", 1, true) ~= nil
  end, 10000)
  eq(#posts(fake), 0)
  vim.fn.delete(dir, "rf")
end

T["an open merge request for the branch is offered instead"] = function()
  local existing = MR.nodes()[1]
  local function list()
    return { request = { operation = "MergeRequestsListProject" }, response = { body = MR.body({ existing }) } }
  end
  local responses = base({
    { ["repeat"] = true, request = { method = "GET", path = BRANCHES .. "/test" }, response = { body = branch("test") } },
  })
  table.insert(responses, 1, list())
  table.insert(responses, 2, list())
  vim.list_extend(responses, X.open_mr_responses())
  local p, s, fake = P.open("merge_request", { source_branch = "test" }, responses)
  settled(p)
  local asked
  vim.ui.input = function(opts, cb)
    asked = opts.prompt
    cb("")
  end
  P.keys("<C-s>")
  H.wait_for(function()
    return p.state == "error"
  end)
  eq(asked, ("!%s already exists for test. Open it instead? [y/N]: "):format(existing.iid))
  eq({ p.closed, #posts(fake) }, { false, 0 })
  eq(P.diagnostics(p, p.group.members.field_source.buf), { ("!%s already exists for test"):format(existing.iid) })
  vim.ui.input = function(_, cb)
    cb("y")
  end
  P.keys("<C-s>")
  H.wait_for(function()
    return p.closed and s:depth() == 2 and s:top().group.members.header ~= nil
  end)
  eq(#posts(fake), 0)
end

T["git helpers: the current branch, and a push that fails"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  eq(H.await(project.current_branch(dir), 5000), false) -- not a repository
  vim.fn.system({ "git", "-C", dir, "init", "-q", "-b", "22-some-feature" })
  eq(H.await(project.current_branch(dir), 5000), "22-some-feature")
  local _, err = H.await(project.push("22-some-feature", dir), 10000)
  eq(err.message:find("git push failed", 1, true), 1)
  eq(select(2, H.await(project.push("--force", dir))).kind, "validation")
  eq(select(2, H.await(project.push("", dir))).kind, "validation")
  vim.fn.delete(dir, "rf")
end

T["git helpers: push to a remote sets the upstream"] = function()
  local root = vim.fn.tempname()
  local remote, work = root .. "/remote.git", root .. "/work"
  vim.fn.mkdir(work, "p")
  vim.fn.system({ "git", "init", "-q", "--bare", remote })
  vim.fn.system({ "git", "-C", work, "init", "-q", "-b", "topic" })
  vim.fn.system({ "git", "-C", work, "-c", "user.name=Test User 1", "-c", "user.email=user1@example.com", "commit", "-q", "--allow-empty", "-m", "init" })
  vim.fn.system({ "git", "-C", work, "remote", "add", "origin", remote })
  local ok, err = H.await(project.push("topic", work), 20000)
  eq({ ok, err }, { true, nil })
  eq(vim.trim(vim.fn.system({ "git", "-C", remote, "branch", "--list", "topic" })):find("topic", 1, true) ~= nil, true)
  vim.fn.delete(root, "rf")
end

T["ref picker: lines, selection, stale answers, fallback"] = function()
  eq({ ref_picker.line({ name = "v1.2", kind = "tag", sha = "abcdef0123456", title = "Release" }) }, {
    " ◆ v1.2  abcdef01  Release",
    { { 0, 9, "GitlabRefTag" }, { 9, 28, "GitlabCreateDim" } }, -- bytes: ◆ takes three
  })
  eq((ref_picker.line({ name = "main", kind = "branch", default = true })), " ⎇ main")
  local calls, picked, closed = {}, nil, nil
  local pk = ref_picker.open({
    title = "Ref",
    row = 2,
    col = 4,
    width = 50,
    debounce_ms = 0,
    load = function(q, cb)
      table.insert(calls, { q, cb })
    end,
    on_pick = function(item)
      picked = item.name
    end,
    on_close = function(p)
      closed = p
    end,
  })
  eq(P.lines(pk.list_float.buf), { " Loading…" })
  -- a newer query's answer wins over an older one that arrives late
  vim.api.nvim_buf_set_lines(pk.prompt_float.buf, 0, -1, false, { "v" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = pk.prompt_float.buf })
  eq(#calls, 2)
  calls[2][2]({ { name = "v1", kind = "tag" }, { name = "v2", kind = "tag" } })
  calls[1][2]({ { name = "main", kind = "branch" } })
  eq(P.lines(pk.list_float.buf), { " ◆ v1", " ◆ v2" })
  pk:move(1)
  pk:move(1) -- wraps
  eq(pk.index, 1)
  pk:move(-1)
  eq(pk.index, 2)
  pk:pick()
  eq({ picked, closed, pk.closed }, { "v2", true, true })
  eq(vim.api.nvim_win_is_valid(pk.list_float.win), false)
  -- no room for the floats: vim.ui.select
  local offered
  vim.ui.select = function(items, opts, cb)
    offered = { opts.prompt, vim.tbl_map(opts.format_item, items) }
    cb(items[2])
  end
  picked = nil
  local none = ref_picker.open({
    title = "Ref",
    row = vim.o.lines - 3,
    col = 0,
    width = 40,
    load = function(_, cb)
      cb({ { name = "a", kind = "branch" }, { name = "b", kind = "branch" } })
    end,
    on_pick = function(item)
      picked = item.name
    end,
  })
  eq({ none, offered, picked }, { nil, { "Ref", { "a", "b" } }, "b" })
end

return T
