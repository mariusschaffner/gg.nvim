-- gg.ui.merge_requests: filter, model, columns, cells, user colours, render
-- (pure; no windows).
local D = require("tests.support.mr_data")
local cells = require("gg.ui.merge_requests.cells")
local columns = require("gg.ui.merge_requests.columns")
local filter = require("gg.ui.merge_requests.filter")
local ps = require("gg.ui.lib.pipeline_status")
local model = require("gg.ui.merge_requests.model")
local render = require("gg.ui.merge_requests.render")
local user_hl = require("gg.ui.lib.user_hl")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function rendered(opts)
  opts = opts or {}
  local mrs = opts.mrs or D.mrs()
  local m = model.build(mrs, { tab = opts.tab or "opened", query = opts.query })
  local pages = model.pages(m.rows, opts.page_size or 50)
  return render.render({
    width = opts.width or 160,
    status = "ready",
    tab = opts.tab or "opened",
    model = m,
    page = pages[1],
    summaries = opts.summaries,
    user_colors = opts.user_colors,
    me = opts.me,
  }), m
end

-- display column where `needle` starts in line `s`
local function col_of(s, needle)
  local i = s:find(needle, 1, true)
  assert(i, ("%q not in %q"):format(needle, s))
  return vim.fn.strdisplaywidth(s:sub(1, i - 1))
end

local function marks_on(r, lnum)
  local out = {}
  for _, m in ipairs(r.marks) do
    if m.row == lnum - 1 then
      table.insert(out, { r.lines[lnum]:sub(m.col + 1, m.end_col), m.hl })
    end
  end
  return out
end

local function hl_of(r, lnum, text)
  local hls = {}
  for _, m in ipairs(marks_on(r, lnum)) do
    if m[1] == text then
      table.insert(hls, m[2])
    end
  end
  return hls
end

T["model: tabs, counts, order, locked counts as open"] = function()
  local mrs = D.mrs()
  mrs[6].state = "locked"
  local m = model.build(mrs, {})
  eq(m.counts, { opened = 6, merged = 2, closed = 1, all = 9 })
  eq(vim.tbl_map(function(x)
    return x.iid
  end, m.rows), { 88, 87, 86, 85, 84, 83 })
  eq(#model.build(mrs, { tab = "merged" }).rows, 2)
  eq(#model.build(mrs, { tab = "all" }).rows, 9)
  -- updated_at desc, then iid desc
  mrs[1].updated_at, mrs[2].updated_at = "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"
  local rows = model.build(mrs, {}).rows
  eq({ rows[#rows - 1].iid, rows[#rows].iid }, { 88, 87 })
end

T["model: pages and page_of"] = function()
  local pages = model.pages(model.build(D.mrs(), { tab = "all" }).rows, 4)
  eq(vim.tbl_map(function(p)
    return p.count
  end, pages), { 4, 4, 1 })
  eq(model.page_of(pages, 84), 2)
  eq(model.page_of(pages, 1), nil)
  eq(#model.pages({}, 10), 1)
end

T["filter: MR tokens"] = function()
  local function iids(q, tab)
    local m = model.build(D.mrs(), { tab = tab or "all", query = q })
    return vim.tbl_map(function(x)
      return x.iid
    end, m.rows)
  end
  eq(iids("!8"), { 88, 87, 86, 85, 84, 83, 80 })
  eq(iids("!88"), { 88 })
  eq(iids("@user-lh"), { 86, 84 }) -- reviewer on !86, assignee on !84
  eq(iids("@none"), { 83, 78 })
  eq(iids("draft"), { 87 })
  eq(iids("winrm"), { 87 })
  eq(iids("feat/oci"), { 86 }) -- the source branch
  eq(iids("@"), iids(""))
  eq(#filter.parse("~ % ! @"), 0)
  eq(filter.parse("!12 @NONE"), { { kind = "iid", value = "12" }, { kind = "user", value = "none", none = true } })
end

T["columns: full width layout"] = function()
  local c = columns.layout(160)
  eq({ c.mark.col, c.iid.col, c.title.col, c.title.width }, { 0, 2, 8, 49 })
  eq({ c.source.col, c.target.col, c.reviewers.col, c.assignee.col, c.pipeline.col, c.diff.col }, { 59, 85, 95, 114, 129, 140 })
  eq(c.diff.col + c.diff.width, 160)
end

T["columns: narrow windows hide Target, Reviewers, the diff bar, then Source"] = function()
  local c = columns.layout(131)
  eq({ c.target ~= nil, c.title.width }, { true, 20 })
  c = columns.layout(130)
  eq({ c.target, c.reviewers ~= nil, c.title.width }, { nil, true, 29 })
  c = columns.layout(120)
  eq({ c.reviewers, c.diff.width, c.title.width }, { nil, 20, 38 })
  c = columns.layout(101)
  eq({ c.source ~= nil, c.diff.width, c.title.width }, { true, 11, 28 })
  c = columns.layout(92)
  eq({ c.source, c.diff.width, c.title.width }, { nil, 11, 45 })
  c = columns.layout(40)
  eq(c.title.width, 20) -- never below 20
end

T["pipeline_status (shared): stage icons and status derivation"] = function()
  eq({ ps.icon("success") }, { "✓", "GitlabPipelineSuccess" })
  eq({ ps.icon("FAILED") }, { "✗", "GitlabPipelineFailed" })
  eq({ ps.icon("running") }, { "◐", "GitlabPipelineRunning" })
  eq({ ps.icon("waiting_for_resource") }, { "○", "GitlabPipelinePending" })
  eq({ ps.icon("scheduled") }, { "○", "GitlabPipelinePending" })
  eq({ ps.icon("manual") }, { "▸", "GitlabPipelineManual" })
  eq({ ps.icon("canceled") }, { "⊘", "GitlabPipelineCanceled" })
  eq({ ps.icon("skipped") }, { "–", "GitlabPipelineSkipped" })
  eq(ps.icon_class("success_with_warnings"), "success")
  eq(ps.icon_class(nil), "pending")
  local function jobs(...)
    return vim.tbl_map(function(s)
      return { status = s }
    end, { ... })
  end
  eq(ps.derive_stage_status(jobs("success", "failed", "running")), "failed")
  eq(ps.derive_stage_status(jobs("success", "running", "manual")), "running")
  eq(ps.derive_stage_status(jobs("success", "manual")), "manual")
  eq(ps.derive_stage_status(jobs("success", "success")), "success")
  eq(ps.derive_stage_status(jobs("success", "created")), "pending")
  eq(ps.derive_stage_status({}), "pending")
  eq(ps.stage_status({ name = "x", jobs = jobs("failed") }), "failed")
  eq(ps.stage_status({ name = "x", status = "success", jobs = jobs("failed") }), "success")
end

T["pipeline_status (shared): stages cell"] = function()
  local function txt(segs)
    return table.concat(vim.tbl_map(function(s)
      return s[1]
    end, segs))
  end
  local function p(...)
    return { status = "running", stages = vim.tbl_map(function(s)
      return { name = s, status = s }
    end, { ... }) }
  end
  eq(txt(ps.stages(p("success", "running", "pending", "pending"))), "✓ ◐ ○ ○")
  eq(txt(ps.stages(p("success", "success", "success", "failed", "pending"))), "✓ ✓ ✓ …")
  eq(txt(ps.stages(nil)), "—")
  eq(txt(ps.stages(nil, { loading = true })), "·")
  eq(txt(ps.stages(p("success"), { failed = true })), "·")
  eq(txt(ps.stages({ status = "failed", stages = {} })), "✗")
end

T["cells: diff numbers, compact counts, bar maths"] = function()
  eq({ cells.compact(0), cells.compact(9999), cells.compact(10000), cells.compact(123456), cells.compact(1234567) }, { "0", "9999", "10k", "123k", "1M" })
  eq(cells.bar_split(120, 34), 6)
  eq(cells.bar_split(310, 12), 7) -- 7.7 rounds to 8, but deletions keep one cell
  eq(cells.bar_split(482, 0), 8)
  eq(cells.bar_split(40, 40), 4)
  eq(cells.bar_split(1, 1000), 1) -- additions keep one cell
  eq(cells.bar_split(0, 5), 0)
  eq(cells.bar_split(0, 0), 0)
  local function txt(segs)
    return table.concat(vim.tbl_map(function(s)
      return s[1]
    end, segs))
  end
  eq(txt(cells.diff({ additions = 120, deletions = 34 }, nil, true)), " +120   −34 ━━━━━━" .. "━━")
  eq(txt(cells.diff({ additions = 12345, deletions = 0 }, nil, false)), " +12k    −0")
  eq(txt(cells.diff({ additions = 0, deletions = 0 }, nil, true)), "   +0    −0 ········")
  eq(txt(cells.diff(nil, { loading = true }, true)), "    ·     · ········")
  for _, segs in ipairs({ cells.diff({ additions = 99999, deletions = 99999 }, nil, true), cells.diff(nil, { loading = true }, true) }) do
    eq(vim.fn.strdisplaywidth(txt(segs)), 20)
  end
end

T["cells: GitLab's 'no stats' value and fallback sums"] = function()
  eq(cells.is_nil_stats({ additions = 0, deletions = 0, file_count = 0 }), true)
  eq(cells.is_nil_stats({ additions = 0, deletions = 0, file_count = 2 }), false) -- e.g. renames only
  eq(cells.is_nil_stats({ additions = 1, deletions = 0, file_count = 0 }), false)
  eq(cells.is_nil_stats(nil), false)
  eq(cells.sum_stats({ { additions = 3, deletions = 1 }, { additions = nil, deletions = nil }, { additions = 2, deletions = 0 } }), { additions = 5, deletions = 1 })
end

T["render: fallback counts replace the summary's; pending fallback shows placeholders"] = function()
  local summaries = D.summaries()
  summaries[88].diff = { additions = 7, deletions = 2 }
  summaries[87].diff_loading = true
  local r = rendered({ summaries = summaries })
  eq(r.lines[6]:find("   +7    −2 ", 1, true) ~= nil, true)
  eq(r.lines[7]:find("    ·     · ········", 1, true) ~= nil, true)
  eq(r.lines[7]:find("✓ ◐ ○ ○", 1, true) ~= nil, true) -- the pipeline is still shown
end

T["user colours: stable hash, overrides, current user bold"] = function()
  eq(user_hl.hash("abc"), 193485963)
  eq(user_hl.group("abc"), "GitlabUser4")
  eq(user_hl.group("abc"), user_hl.group("abc"))
  for _, name in ipairs({ "a", "user-ma", "user-sf", "x_y.z", "日本" }) do
    local g = user_hl.group(name)
    local n = tonumber(g:match("^GitlabUser(%d)$"))
    eq(n ~= nil and n >= 1 and n <= 8, true)
  end
  eq(user_hl.group("abc", { abc = "GitlabUser1" }), "GitlabUser1")
  eq(user_hl.item("me", nil, "me"), { "@me", user_hl.group("me"), "GitlabCurrentUser" })
  eq(user_hl.item("you", nil, "me")[3], nil)
end

T["render: head lines, every column lined up, drafts, missing data"] = function()
  local r = rendered({ summaries = D.summaries() })
  eq(r.lines[2], "    Open 6     Merged 2     Closed 1     All 9  ")
  eq(r.lines[3], "")
  local h = r.lines[4]
  eq({ col_of(h, "!"), col_of(h, "Title"), col_of(h, "Source"), col_of(h, "Target") }, { 2, 8, 59, 85 })
  eq({ col_of(h, "Reviewers"), col_of(h, "Assignee"), col_of(h, "Pipeline"), col_of(h, "Diff") }, { 95, 114, 129, 140 })
  eq(#r.lines[5], #"─" * 160)
  eq(r.selectable, { 6, 7, 8, 9, 10, 11 })
  -- no rules between the rows
  eq(#r.virt_lines, 0)
  local c = r.columns
  for _, lnum in ipairs(r.selectable) do
    local s = r.lines[lnum]
    local mr = r.rows[lnum].mr
    eq(r.rows[lnum].mark_col, 0)
    eq(col_of(s, "!" .. mr.iid), c.iid.col)
    eq(col_of(s, mr.source_branch), c.source.col)
    eq(col_of(s, "main"), c.target.col)
    eq(col_of(s, "✓"), c.pipeline.col)
    -- the bar starts in the same column on every row
    eq(col_of(s, cells.BAR), c.diff.col + 12)
  end
  local draft = r.lines[7]
  eq(col_of(draft, "[Draft] WinRM"), c.title.col)
  eq(hl_of(r, 7, "[Draft] "), { "GitlabDraft" })
  -- no reviewers: "—"; no assignee: "unassigned"
  eq(col_of(draft, "—"), c.reviewers.col)
  eq(hl_of(r, 11, "unassigned"), { "GitlabUnassigned" })
  eq(col_of(r.lines[11], "unassigned"), c.assignee.col)
  -- pipeline and diff
  eq(r.lines[6]:find("✓ ✓ ✓ ▸", 1, true) ~= nil, true)
  eq(r.lines[6]:find(" +120   −34 ", 1, true) ~= nil, true)
  eq(hl_of(r, 8, "✗"), { "GitlabPipelineFailed" })
end

T["render: cells show placeholders until their summary loads"] = function()
  local summaries = D.summaries()
  summaries[87] = nil -- still loading
  summaries[86] = { updated_at = "x", error = true } -- the request failed
  summaries[85].summary.failed = { diff_stats = true }
  summaries[85].summary.diff_stats = nil
  local r = rendered({ summaries = summaries })
  local c = r.columns
  -- the text of display columns [col, col + w) of line `lnum`
  local function cell(lnum, col, w)
    local s = r.lines[lnum]
    local chars, cw = {}, 0
    for i = 0, vim.fn.strchars(s) - 1 do
      local ch = vim.fn.strcharpart(s, i, 1)
      if cw >= col and cw < col + w then
        table.insert(chars, ch)
      end
      cw = cw + vim.fn.strdisplaywidth(ch)
    end
    return table.concat(chars)
  end
  eq(cell(7, c.pipeline.col, c.pipeline.width), "·        ")
  eq(cell(7, c.diff.col, c.diff.width), "    ·     · ········")
  eq(cell(8, c.pipeline.col, 1), "·")
  eq(cell(9, c.pipeline.col, 7), "✓ ✓ ✓ ▸") -- the pipeline loaded
  eq(cell(9, c.diff.col, 11), "    ·     ·") -- its diff stats failed
  -- nothing loaded yet: every row still lines up
  r = rendered({})
  for _, lnum in ipairs(r.selectable) do
    eq(col_of(r.lines[lnum], "·"), c.pipeline.col)
  end
end

T["render: user colours, current user bold, truncation with wide glyphs"] = function()
  local mrs = D.mrs()
  mrs[3].reviewers = {
    { username = "ユーザー名がとても長い" },
    { username = "user-sf" },
  }
  mrs[1].title = "日本語のタイトルがとても長い場合のテストです。さらに長くしてみましょう。"
  mrs[1].source_branch = "feat/an-extremely-long-branch-name-that-will-not-fit"
  mrs[4].assignees = { { username = "user-sf" }, { username = "user-lh" }, { username = "user-ma" } }
  local r = rendered({ mrs = mrs, summaries = D.summaries(), me = "user-ma", user_colors = { ["user-sf"] = "GitlabUser1" } })
  local c = r.columns
  -- the same user gets the same colour everywhere; pinned users their pin
  eq(hl_of(r, 6, "@user-ma"), { user_hl.group("user-ma"), "GitlabCurrentUser" })
  eq(hl_of(r, 9, "@user-ma"), { user_hl.group("user-ma"), "GitlabCurrentUser" })
  eq(hl_of(r, 6, "@user-sf"), { "GitlabUser1" })
  eq(hl_of(r, 9, "@user-sf"), { "GitlabUser1" })
  -- assignee "+N"
  eq(r.lines[9]:find("@user-sf +2", 1, true) ~= nil, true)
  -- wide title and long branch cut with "…", the rest stays aligned
  local s = r.lines[6]
  eq(s:find("…", 1, true) ~= nil, true)
  eq(col_of(s, "feat/an-extremely"), c.source.col)
  eq(col_of(s, "main"), c.target.col)
  eq(col_of(s, "✓"), c.pipeline.col)
  -- a wide reviewer name is cut inside its column
  local row = r.lines[8]
  eq(col_of(row, "@ユーザー"), c.reviewers.col)
  eq(col_of(row, "@user-ma"), c.assignee.col)
end

T["render: narrow width keeps the diff numbers, drops the bar"] = function()
  local r = rendered({ width = 101, summaries = D.summaries() })
  local c = r.columns
  eq({ c.target, c.reviewers, c.diff.width }, { nil, nil, 11 })
  local h = r.lines[4]
  eq(h:find("Target", 1, true), nil)
  eq(h:find("Reviewers", 1, true), nil)
  eq(r.lines[6]:find(cells.BAR, 1, true), nil)
  eq(vim.endswith(r.lines[6], " +120   −34"), true)
end

T["render: states"] = function()
  local loading = render.render({ width = 140, status = "loading", tab = "opened", loaded = 3 })
  eq(loading.lines[2], "    Open …     Merged …     Closed …     All …  ")
  eq(loading.lines[6], "  Loading merge requests… (3)")
  local err = render.render({ width = 140, status = "error", tab = "opened", error = "boom", retry_key = "R" })
  eq({ err.lines[6], err.lines[7] }, { "  Failed to load merge requests: boom", "  [R] Retry" })
  local empty = rendered({ query = "no-such-thing" })
  eq(empty.lines[6], "  No merge requests match")
  local m = model.build(D.mrs(), { tab = "merged" })
  local pend = render.render({ width = 140, status = "ready", tab = "closed", model = model.build({}, { tab = "closed" }), page = model.pages({}, 5)[1], pending = { opened = false, merged = false, closed = true } })
  eq(pend.lines[6], "  Loading merge requests…")
  eq(m.counts.merged, 2)
end

return T
