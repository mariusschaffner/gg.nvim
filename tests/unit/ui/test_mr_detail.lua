-- The merge request detail view: readiness, closing refs, changes,
-- commits, the strip (pure), and the view end to end.
local H = require("tests.helpers")
local X = require("tests.support.detail_data")
local changes = require("gg.ui.detail.merge_request.changes")
local closing_refs = require("gg.ui.detail.merge_request.closing_refs")
local commits = require("gg.ui.detail.merge_request.commits")
local config = require("gg.ui.config")
local date = require("gg.ui.lib.date")
local detail = require("gg.ui.detail")
local readiness = require("gg.ui.detail.merge_request.readiness")
local stack = require("gg.ui.components.stack")
local strip = require("gg.ui.lib.strip")
local text = require("gg.ui.lib.text")
local eq = MiniTest.expect.equality

local s
local saved = {}

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { columns = vim.o.columns, lines = vim.o.lines, utc = date.utc_offset }
      vim.o.columns, vim.o.lines = 170, 50
      date.utc_offset = function()
        return 0
      end
    end,
    post_case = function()
      if s and not s:is_closed() then
        s:close()
      end
      s = nil
      date.utc_offset = saved.utc
      vim.o.columns, vim.o.lines = saved.columns, saved.lines
      config.setup()
      H.reset()
    end,
  },
})

local function gate_states(r)
  return vim.tbl_map(function(g)
    return g.key .. ":" .. g.state
  end, r.gates)
end

local mr = { state = "opened", target_branch = "main", draft = false }
local reviewer = function(name, state, approved, role)
  return { user = { username = name }, review_state = state, approved = approved or false, role = role or "reviewer" }
end

T["readiness: gates and the blocking one"] = function()
  local r = readiness.compute({
    mr = mr,
    checks = { detailed_merge_status = "ci_must_pass", head_pipeline_status = "running", resolvable_discussions = 2, resolved_discussions = 2, discussions_resolved = true },
    reviewers = { reviewer("ann", "unreviewed") },
  })
  eq(gate_states(r), { "pipeline:pending", "conflicts:passed", "review:pending", "threads:passed" })
  eq(r.blocking, "pipeline")
  eq(r.merge, { state = "blocked", label = "Merge into main" })
  eq(r.gates[3].label, "Review · ann")
  -- changes requested, conflicts, unresolved threads, draft
  r = readiness.compute({
    mr = { state = "opened", target_branch = "main", draft = true },
    checks = { detailed_merge_status = "discussions_not_resolved", has_conflicts = true, resolvable_discussions = 3, resolved_discussions = 1, discussions_resolved = false },
    reviewers = { reviewer("ann", "requested_changes"), reviewer("bob", "approved", true) },
  })
  eq(gate_states(r), { "conflicts:failed", "review:failed", "threads:failed", "draft:failed" })
  eq(r.blocking, "threads")
  eq(r.gates[1].label, "Conflicts with main")
  eq(r.gates[2].label, "Changes requested · ann")
  eq(r.gates[3].label, "2 unresolved threads")
  -- mergeable
  r = readiness.compute({
    mr = mr,
    checks = { detailed_merge_status = "mergeable", head_pipeline_status = "success", approved = true },
    reviewers = { reviewer("ann", "approved", true) },
  })
  eq(r.merge, { state = "ready", label = "Ready to merge" })
  eq(r.blocking, nil)
  eq(r.gates[3].label, "Approved · ann")
  -- blocked by something that is not a gate
  r = readiness.compute({ mr = mr, checks = { detailed_merge_status = "need_rebase" } })
  eq(r.merge.reason, "needs rebase")
  -- merged: green with neutral labels
  r = readiness.compute({ mr = { state = "merged", target_branch = "main" }, checks = { head_pipeline_status = "failed" } })
  eq(gate_states(r), { "pipeline:passed", "conflicts:passed" })
  eq({ r.gates[1].label, r.merge.label }, { "Pipeline", "Merged into main" })
end

T["readiness nodes and the strip"] = function()
  local r = readiness.compute({ mr = mr, checks = { detailed_merge_status = "not_approved", head_pipeline_status = "success" }, reviewers = { reviewer("ann", "unreviewed") } })
  local nodes = readiness.nodes(r, { pipeline_key = "gp" })
  eq(#nodes, 4)
  local d = strip.render(nodes, 120)
  eq(#d.lines, 3)
  eq(vim.startswith(d.lines[1], " (✓)━"), true)
  eq(vim.endswith(d.lines[1], "(⇣)"), true)
  eq(text.width(d.lines[1]), 121)
  eq(vim.startswith(d.lines[2], " Pipeline passed"), true)
  eq(vim.endswith(d.lines[2], "Merge into main"), true)
  eq(d.lines[3]:find("[gp] pipeline", 1, true) ~= nil, true)
  eq(d.lines[3]:find("waiting for approval", 1, true) ~= nil, true)
  eq(vim.endswith(d.lines[3], "blocked"), true)
  local compact = table.concat(vim.tbl_map(function(sg)
    return sg[1]
  end, strip.compact(nodes, "blocked")))
  eq(compact, "✓ pipeline · ✓ no conflicts · ◷ review · ⇣ merge · blocked")
end

T["closing refs"] = function()
  local refs = closing_refs.parse(table.concat({
    "Closes #12",
    "fixes: group/sub/proj#3 and #4, #5",
    "Resolves issue #12",
    "mentions #99 only",
    "```",
    "closes #77",
    "```",
    "Implemented #6",
  }, string.char(10)))
  eq(vim.tbl_map(function(r)
    return r.key .. "@" .. r.line
  end, refs), { "#12@1", "group/sub/proj#3@2", "#4@2", "#5@2", "#6@8" })
  eq(refs[2].project, "group/sub/proj")
end

T["changes: bars, paths, table"] = function()
  eq({ changes.bar_cells(100, 30, 130) }, { 8, 2 })
  eq({ changes.bar_cells(20, 4, 130) }, { 1, 1 })
  eq({ changes.bar_cells(1, 0, 1000) }, { 1, 0 })
  eq({ changes.bar_cells(0, 0, 10) }, { 0, 0 })
  eq({ changes.split_path("a/b/c.lua", 20) }, { "a/b/", "c.lua" })
  eq({ changes.split_path("roles/webaccess/tasks/main.yml", 20) }, { "…/tasks/", "main.yml" })
  eq({ changes.split_path("averyveryverylongfilename.lua", 10) }, { "", "averyvery…" })
  local d = changes.render({ width = 60, status = "ready", files = { { path = "a.lua", additions = 3, deletions = 1 } } })
  eq(#d.lines, 4)
  eq(vim.endswith(d.lines[2], "+3     −1  ■■■■■■■■■■"), true)
  eq(vim.startswith(d.lines[4], "   1 file changed"), true)
  eq(changes.render({ width = 60, status = "ready", files = {} }).lines, { " No changes." })
end

T["commits: parse, render, separators"] = function()
  eq(commits.parse("feat(ui): add things"), { type = "feat", scope = "ui", breaking = false, subject = "add things" })
  eq(commits.parse("fix!: urgent"), { type = "fix", breaking = true, subject = "urgent" })
  eq(commits.parse("Merge branch 'feature-x' into 'main'"), { type = "merge", subject = "feature-x → main", breaking = false })
  eq(commits.parse("plain title"), { subject = "plain title", breaking = false })
  local list = {
    { sha = "a1", short_sha = "a1a1a1a1", title = "feat: one", authored_date = "2026-11-10T08:00:00Z", author = { username = "ann", name = "Ann" } },
    { sha = "b2", short_sha = "b2b2b2b2", title = "fix: two", authored_date = "2026-11-09T08:00:00Z", author_name = "Bob" },
    { sha = "c3", short_sha = "c3c3c3c3", title = "feat: three", authored_date = "2026-11-09T07:00:00Z" },
  }
  local d = commits.render({ width = 60, status = "ready", commits = list, today = X.TODAY, utc_offset = 0 })
  eq(vim.startswith(d.lines[1], "──── TODAY · 10.11.2026 ─"), true)
  eq(vim.startswith(d.lines[2], " ○   feat "), true)
  eq(vim.endswith(d.lines[2], "08:00  Ann  a1a1a1a1"), true)
  eq(d.lines[3], " │   one")
  eq(d.lines[4], "") -- no rule before the next day
  eq(vim.startswith(d.lines[5], "──── YESTERDAY · 09.11.2026"), true)
  eq(d.lines[7], " │   two")
  -- a rule between commits of a day; the graph line runs through it
  eq(d.lines[8], " │  " .. string.rep("─", 56))
  eq(d.rows[8], { kind = "separator" })
  eq(vim.startswith(d.lines[9], " ○   feat "), true)
  eq(d.lines[10], " │   three")
  eq(#d.lines, 10)
end

local function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "x", false)
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function open()
  local fake = H.fake()
  fake:add(X.mr_responses())
  s = stack.new()
  detail.merge_request({
    stack = s,
    cfg = config.get(),
    host = X.HOST,
    project = X.PROJECT,
    today = X.TODAY,
    now = function()
      return date.parse_time(X.NOW)
    end,
  }, { iid = X.MR_IID })
  local g = s:top().group
  H.wait_for(function()
    local c = lines(g.members.content.buf)
    local hd = lines(g.members.header.buf)
    return #c > 4 and c[5]:find("#214", 1, true) ~= nil and hd[4] ~= nil and hd[4]:find("(✓)", 1, true) ~= nil
  end)
  return g, fake
end

T["view: header strip, sidebar, description cards"] = function()
  local g = open()
  local hl = lines(g.members.header.buf)
  eq(hl[1], "")
  eq(vim.startswith(hl[2], "  ● Merged  Rotate Terraform state backend credentials !88"), true)
  eq(vim.startswith(hl[5], " Pipeline "), true)
  eq(vim.endswith(hl[5], "Merged into main"), true)
  eq(hl[#hl], "")
  local side = table.concat(lines(g.members.sidebar.buf), "\n")
  eq(side:find("⎇ 8568-share-local-config", 1, true) ~= nil, true)
  eq(side:find("(T1) user-1         ✓ approved", 1, true) ~= nil, true)
  eq(side:find("● Close #214", 1, true) ~= nil, true)
  local c = lines(g.members.content.buf)
  eq(c[1], "")
  eq(c[4], " Closes #214 and #211")
  eq(vim.startswith(c[5], "  ● #214  Rotate Terraform state backend credentials"), true)
  eq(vim.endswith(c[5], "WF:Review "), true)
  eq(vim.startswith(c[6], "  ● #211  WinRM over HTTPS"), true)
  local footer = table.concat(vim.tbl_map(function(ch)
    return ch[1]
  end, vim.api.nvim_win_get_config(g.members.content.win).footer))
  eq(footer, " [i] Edit ")
  -- <CR> on a card opens the issue
  local got
  local real = detail.issue
  detail.issue = function(ctx, issue)
    got = { issue.iid, ctx.project }
  end
  vim.api.nvim_win_set_cursor(g.members.content.win, { 6, 0 })
  local notify = vim.notify
  vim.notify = function() end
  local ok, err = pcall(keys, "i") -- `i` is the edit key here, not open
  vim.notify = notify
  assert(ok, err)
  eq(got, nil)
  ok, err = pcall(keys, "<CR>")
  detail.issue = real
  assert(ok, err)
  eq(got, { 211, X.PROJECT })
end

T["view: Changes, Commits, Activity tabs"] = function()
  local g = open()
  local win = g.members.content.win
  keys("<Tab>")
  H.wait_for(function()
    return (lines(vim.api.nvim_win_get_buf(win))[2] or ""):find("04.03.2018", 1, true) ~= nil
  end)
  local a = lines(vim.api.nvim_win_get_buf(win))
  eq(a[6]:find("⎇ package.json:27  ✓ resolved thread", 1, true) ~= nil, true)
  -- no key hints under the activity, and no footer breaking the border
  eq(vim.api.nvim_win_get_config(win).footer, nil)
  keys("<Tab>")
  local c = lines(vim.api.nvim_win_get_buf(win))
  eq(c[3]:find("internal/commands/mr/view.go", 1, true) ~= nil, true)
  eq(vim.startswith(c[6], "   2 files changed"), true)
  local cfoot = table.concat(vim.tbl_map(function(ch)
    return ch[1]
  end, vim.api.nvim_win_get_config(win).footer))
  eq(cfoot, " [i] File ")
  -- opening a file comes with the review view: the key says so
  local notes = {}
  local notify = vim.notify
  vim.notify = function(msg)
    table.insert(notes, msg)
  end
  keys("i")
  vim.notify = notify
  eq(notes, { "gg.ui: opening a file is not available yet" })
  keys("<Tab>")
  local m = lines(vim.api.nvim_win_get_buf(win))
  eq(m[4], " │   return false on any stat error, not just missing")
  -- no hints and no type counts under the commits
  eq(vim.api.nvim_win_get_config(win).footer, nil)
  local title = table.concat(vim.tbl_map(function(ch)
    return ch[1]
  end, vim.api.nvim_win_get_config(win).title))
  eq(title, " Description   Activity 3   Changes 2   Commits   Pipelines  ") -- no commit count
end

T["view: Pipelines tab is the pipelines table of this MR; i opens one; q stops it"] = function()
  local g, fake = open()
  local win = g.members.content.win
  keys("<Tab><Tab><Tab><Tab>")
  H.wait_for(function()
    return (lines(vim.api.nvim_win_get_buf(win))[4] or ""):find("✗ failed", 1, true) ~= nil
  end)
  local l = lines(vim.api.nvim_win_get_buf(win))
  -- one table of every pipeline: no All / Running / Failed / Passed line
  eq(l[2]:find("Status", 1, true) ~= nil, true)
  eq(table.concat(l, " "):find("Running", 1, true), nil)
  local footer = table.concat(vim.tbl_map(function(ch)
    return ch[1]
  end, vim.api.nvim_win_get_config(win).footer))
  eq(footer, " [i] Pipeline ")
  for _, r in ipairs(fake:requests()) do
    if r.operation == "PipelinesListMr" then
      eq(r.variables.iid, tostring(X.MR_IID))
    end
  end
  eq(vim.api.nvim_win_get_cursor(win)[1], 4)
  local got
  local real = detail.pipeline
  detail.pipeline = function(ctx, p)
    got = { p.id, ctx.project }
  end
  local ok, err = pcall(keys, "j<CR>")
  detail.pipeline = real
  assert(ok, err)
  eq(got, { 3037518193, X.PROJECT })
  keys("q")
  eq(s:is_closed(), true)
end

T["view: gp opens the newest pipeline"] = function()
  open()
  local got
  local real = detail.pipeline
  detail.pipeline = function(_, p)
    got = p.id
  end
  local ok, err = pcall(function()
    keys("gp")
    H.wait_for(function()
      return got ~= nil
    end)
  end)
  detail.pipeline = real
  assert(ok, err)
  eq(got, 3037601527)
end

return T
