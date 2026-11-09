-- gg.ui.pipelines: status / source mapping, tabs, MR link, filter, columns,
-- relative times, render (pure; no windows).
local D = require("tests.support.pipeline_data")
local columns = require("gg.ui.pipelines.columns")
local date = require("gg.ui.lib.date")
local filter = require("gg.ui.pipelines.filter")
local model = require("gg.ui.pipelines.model")
local ps = require("gg.ui.lib.pipeline_status")
local render = require("gg.ui.pipelines.render")
local text = require("gg.ui.lib.text")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function txt(segs)
  return table.concat(vim.tbl_map(function(s)
    return s[1]
  end, segs))
end

T["status cell: icon + word per GitLab status, warnings marker"] = function()
  local cases = {
    success = "✓ passed",
    failed = "✗ failed",
    running = "◐ running",
    pending = "○ pending",
    created = "○ pending",
    preparing = "○ pending",
    waiting_for_resource = "○ pending",
    manual = "▸ waiting",
    scheduled = "○ scheduled",
    canceled = "⊘ canceled",
    skipped = "– skipped",
  }
  for status, want in pairs(cases) do
    eq(txt(ps.status_cell(status)), want)
  end
  -- the word has the icon's colour, like the stage icons
  eq(ps.status_cell("failed")[1][2], "GitlabPipelineFailed")
  eq(ps.status_cell("manual")[1][2], "GitlabPipelineManual")
  eq(txt(ps.status_cell("success", true)), "✓ passed !")
  eq(ps.status_cell("success", true)[3], { "!", "DiagnosticWarn" })
  eq(txt(ps.status_cell("failed", true)), "✗ failed") -- only passed pipelines warn
  eq(ps.word("SUCCESS"), "passed")
  eq(ps.word("something_new"), "something_new")
end

T["source labels"] = function()
  local cases = {
    push = "push",
    merge_request_event = "MR",
    schedule = "schedule",
    web = "manual",
    api = "api",
    trigger = "trigger",
    pipeline = "trigger",
    parent_pipeline = "child",
    duo_workflow = "duo_workflow",
  }
  for source, want in pairs(cases) do
    eq(model.source_label(source), want)
  end
  eq(model.source_label(nil), "")
end

T["tabs: membership and counts"] = function()
  local function tab(status)
    return model.tab_of({ status = status })
  end
  for _, s in ipairs({ "running", "pending", "created", "preparing", "waiting_for_resource" }) do
    eq(tab(s), "running")
  end
  eq({ tab("failed"), tab("success") }, { "failed", "passed" })
  for _, s in ipairs({ "manual", "canceled", "skipped", "scheduled" }) do
    eq(tab(s), nil) -- All only
  end
  local m = model.build(D.pipelines(), { tab = "all" })
  eq(m.counts, { all = 8, running = 1, failed = 2, passed = 3 })
  eq(#m.rows, 8)
  eq(m.rows[1].id, 4821) -- newest first
  eq(#model.build(D.pipelines(), { tab = "failed" }).rows, 2)
  eq(model.is_active({ status = "running" }), true)
  eq(model.is_active({ status = "manual" }), false)
end

T["merge request link: own MR, MR ref, open MR of the branch"] = function()
  local ctx = { mr_by_branch = { ["feat/x"] = 9, main = 1 } }
  eq({ model.mr_of({ ref = "feat/x", merge_request = { iid = 5 } }, ctx) }, { 5, false })
  eq({ model.mr_of({ ref = "refs/merge-requests/87/head" }, ctx) }, { 87, false })
  eq({ model.mr_of({ ref = "refs/merge-requests/12/train" }, {}) }, { 12, false })
  eq({ model.mr_of({ ref = "feat/x" }, ctx) }, { 9, false })
  eq({ model.mr_of({ ref = "feat/y" }, ctx) }, { nil, false })
  eq({ model.mr_of({ ref = "feat/x", tag = true }, ctx) }, { nil, false })
  eq({ model.mr_of({ ref = "feat/x" }, {}) }, { nil, true }) -- still loading
  eq({ model.mr_of({ ref = "feat/x" }, { mr_failed = true }) }, { nil, false })
  -- the branch of a merge request pipeline
  eq(model.display_ref({ ref = "refs/merge-requests/85/head", ref_path = "refs/heads/feat/dns01-wildcard" }), "feat/dns01-wildcard")
  eq(model.display_ref({ ref = "refs/merge-requests/85/head" }), "refs/merge-requests/85/head")
  eq(model.display_ref({ ref = "v1.0", ref_path = "refs/tags/v1.0" }), "v1.0")
  -- open MRs by branch: only this project's branches, the latest update wins
  local map = model.mr_map({
    { iid = 1, source_branch = "a", source_project_id = 42, updated_at = "2026-11-01T00:00:00Z" },
    { iid = 2, source_branch = "a", source_project_id = 42, updated_at = "2026-11-02T00:00:00Z" },
    { iid = 3, source_branch = "b", source_project_id = 99, updated_at = "2026-11-03T00:00:00Z" },
  }, 42)
  eq(map, { a = 2 })
end

T["filter tokens"] = function()
  local ps_list = D.pipelines()
  local ctx = { mr_by_branch = { ["feat/winrm-https"] = 87, ["feat/oci-edge-lb"] = 86 } }
  local function ids(query)
    return vim.tbl_map(function(p)
      return p.id
    end, model.build(ps_list, { query = query, ctx = ctx }).rows)
  end
  eq(ids("status:failed"), { 4819, 4806 })
  eq(ids("status:waiting"), { 4817 })
  eq(ids("status:manual"), { 4817 })
  eq(ids("STATUS:pass"), { 4815, 4812, 4808 })
  eq(ids("source:schedule"), { 4808, 4806 })
  eq(ids("source:MR"), { 4815 })
  eq(ids("ref:main"), { 4812, 4808, 4806 })
  eq(ids("ref:dns01"), { 4815 }) -- the MR pipeline's branch
  eq(ids("@user-sf"), { 4806 })
  eq(ids("#4821"), { 4821 })
  eq(ids("4821"), { 4821 })
  eq(ids("!87"), { 4821 })
  eq(ids("!85"), { 4815 })
  eq(ids("c4a81"), { 4806 }) -- SHA
  eq(ids("drift"), { 4808, 4806 }) -- commit title
  eq(ids("nightly status:failed"), { 4806 }) -- AND
  eq(#ids("status:"), 8) -- a bare key matches everything
  eq(#ids("#"), 8)
  eq(filter.parse("status:failed ref: @x"), { { kind = "status", value = "failed" }, { kind = "user", value = "x" } })
end

T["relative time"] = function()
  local now = D.NOW
  local function at(ago)
    return date.relative(os.date("!%Y-%m-%dT%H:%M:%SZ", now - ago), now)
  end
  eq({ at(0), at(4), at(12), at(59) }, { "now", "now", "12s ago", "59s ago" })
  eq({ at(60), at(120), at(3599) }, { "1m ago", "2m ago", "59m ago" })
  eq({ at(3600), at(3 * 3600), at(86399) }, { "1h ago", "3h ago", "23h ago" })
  eq({ at(86400), at(2 * 86400), at(7 * 86400) }, { "1d ago", "2d ago", "7d ago" })
  eq(at(8 * 86400), "Nov 01")
  eq(at(-30), "now") -- clock skew
  eq(date.relative(nil, now), "")
  eq(date.relative("2026-11-01T23:30:00Z", now, 3600), "Nov 02") -- in the local zone
  eq(date.parse_time("2026-11-09T12:00:00Z"), now)
  eq(date.parse_time("2026-11-09T13:00:00.123+01:00"), now)
  eq(date.parse_time("2026-11-09T07:00:00-05:00"), now)
  eq(date.parse_time("1970-01-01"), 0)
  eq(date.parse_time("2000-02-29T00:00:00Z"), 951782400)
  eq(date.parse_time("nope"), nil)
  -- Started falls back to created_at
  eq(render.started({ created_at = "2026-11-09T11:58:00Z" }, now), "2m ago")
  eq(render.started({ created_at = "2026-11-09T11:00:00Z", started_at = "2026-11-09T11:58:00Z" }, now), "2m ago")
end

T["columns: widths and the narrow-window hiding order"] = function()
  local c = columns.layout(170, 6)
  eq({ c.mark.col, c.status.col, c.id.col, c.ref.col, c.mr.col, c.commit.col }, { 0, 2, 15, 23, 52, 60 })
  eq({ c.commit.width, c.source.width, c.stages.width, c.started.width }, { 77, 10, 9, 8 })
  eq(c.started.col + c.started.width, 170)
  local function shown(w)
    local l = columns.layout(w, 6)
    return { mr = l.mr ~= nil, source = l.source ~= nil, ref = l.ref and l.ref.width or false, started = l.started ~= nil }
  end
  eq(shown(113), { mr = true, source = true, ref = 27, started = true })
  eq(shown(112), { mr = false, source = true, ref = 27, started = true }) -- MR first
  eq(shown(104), { mr = false, source = false, ref = 27, started = true }) -- then Source
  eq(shown(92), { mr = false, source = false, ref = 14, started = true }) -- then Ref shrinks
  eq(shown(79), { mr = false, source = false, ref = false, started = true }) -- then Ref hides
  eq(shown(63), { mr = false, source = false, ref = false, started = false }) -- then Started
  eq(columns.layout(40, 6).commit.width, 20) -- never below 20
  eq(columns.id_width({ { id = 3046451100 }, { id = 7 } }), 11)
  eq(columns.id_width({ { id = 7 } }), columns.ID_MIN)
end

local function rendered(opts)
  opts = opts or {}
  local list = opts.pipelines or D.pipelines()
  local ctx = opts.ctx or { default_branch = "main", mr_by_branch = { ["feat/winrm-https"] = 87, ["feat/oci-edge-lb"] = 86, ["feat/rotate-tf-creds"] = 88, ["fix/backup-weekend"] = 84 } }
  return render.render({
    width = opts.width or 170,
    status = "ready",
    tab = opts.tab or "all",
    model = model.build(list, { tab = opts.tab or "all", query = opts.query, ctx = ctx }),
    id_width = columns.id_width(list),
    ctx = ctx,
    now = D.NOW,
    more = opts.more,
    loaded = #list,
  })
end

local function marks_on(r, lnum)
  local out = {}
  for _, m in ipairs(r.marks) do
    if m.row == lnum - 1 then
      out[r.lines[lnum]:sub(m.col + 1, m.end_col)] = m.hl
    end
  end
  return out
end

T["render: tabs, header, rows like the mockup"] = function()
  local r = rendered()
  eq(r.lines[1], "  All 8     Running 1     Failed 2     Passed 3  ")
  local header = r.lines[3]
  local c = r.columns
  for name, label in pairs({ status = "Status", id = "#", ref = "Ref", mr = "MR", commit = "Commit", source = "Source", stages = "Stages" }) do
    eq(header:sub(c[name].col + 1, c[name].col + #label), label)
  end
  eq(header:sub(-#"Started"), "Started") -- right-aligned
  eq(text.width(header), 170)
  eq(#r.selectable, 8)
  eq(#r.virt_lines, 8) -- a thin separator below every row
  local first = r.lines[r.selectable[1]]
  for _, part in ipairs({ "◐ running", "#4821", "feat/winrm-https", "!87", "a1f3c9e0 Add HTTPS listener task", "push", "✓ ◐ ○ ○" }) do
    eq(first:find(part, 1, true) ~= nil, true)
  end
  eq(first:sub(-#"2m ago"), "2m ago")
  eq(text.width(first), 170) -- Started ends at the right edge
  eq(r.rows[r.selectable[1]].pipeline.id, 4821)
  local hl = marks_on(r, r.selectable[1])
  eq({ hl["feat/winrm-https"], hl["a1f3c9e0"], hl["#4821"], hl["!87"], hl["push"] }, { "GitlabBranchSource", "GitlabSha", "GitlabIid", "GitlabIid", "GitlabPipelineSource" })
  -- the MR pipeline shows its branch, "MR" as source and its own MR
  local mr_line = r.lines[r.selectable[4]]
  eq({ mr_line:find("feat/dns01-wildcard", 1, true) ~= nil, mr_line:find("!85", 1, true) ~= nil, mr_line:find(" MR ", 1, true) ~= nil }, { true, true, true })
  -- the default branch and schedules have their own colours; no MR on main
  local main = marks_on(r, r.selectable[7])
  eq({ main["main"], main["schedule"] }, { "GitlabRefDefault", "GitlabPipelineSourceSchedule" })
  eq(r.lines[r.selectable[7]]:find("!", 1, true), nil)
  eq(r.lines[r.selectable[6]]:find("1d ago", 1, true) ~= nil, true)
end

T["render: tags, warnings, the MR placeholder and more pages"] = function()
  local list = D.pipelines(D.specs_page2())
  local r = rendered({ pipelines = list, ctx = { default_branch = "main" }, more = true })
  eq(r.lines[1]:find("(first 2)", 1, true) ~= nil, true)
  local tag = marks_on(r, r.selectable[1])
  eq(tag["v1.4.0"], "GitlabRefTag")
  eq(r.lines[r.selectable[2]]:find("✓ passed !", 1, true) ~= nil, true)
  eq(r.lines[r.selectable[2]]:find("manual", 1, true) ~= nil, true) -- source "web"
  -- open MRs still loading: "·" for branch pipelines, nothing for tags
  local function mr_cell(lnum)
    local l = r.lines[lnum]
    local at = l:find(ps.PLACEHOLDER, 1, true)
    return at and vim.fn.strwidth(l:sub(1, at - 1)) or nil
  end
  eq({ mr_cell(r.selectable[1]), mr_cell(r.selectable[2]) }, { nil, r.columns.mr.col })
end

-- whole lines are measured with strwidth: strdisplaywidth (text.width) adds
-- a cell where a wide character would wrap at the edge of the (80-column,
-- headless) current window; the renderer only measures short pieces
local sw = vim.fn.strwidth

T["render: multi-byte refs and titles are cut by display width"] = function()
  local specs = D.specs()
  specs[1].ref = "feat/ünïcödé-ブランチ-with-a-very-long-name"
  specs[1].title = "日本語のコミットタイトルがとても長い場合の切り詰めテスト ✓ ✗ ◐"
  for _, w in ipairs({ 170, 100, 90, 70 }) do
    local r = rendered({ pipelines = D.pipelines(specs), width = w })
    local l = r.lines[r.selectable[1]]
    eq(sw(l) <= w, true)
    eq(l:find("…", 1, true) ~= nil, true)
    -- the stages still start where the layout says
    local at = l:find("✓ ◐ ○ ○", 1, true)
    eq(sw(l:sub(1, at - 1)), r.columns.stages.col)
    eq(sw(l), w) -- Started still ends at the right edge
  end
end

T["render: loading, error and empty states"] = function()
  local r = render.render({ width = 120, status = "loading", tab = "all", now = D.NOW })
  eq(r.lines[5]:find("Loading pipelines…", 1, true) ~= nil, true)
  eq(r.lines[1]:find("All …", 1, true) ~= nil, true)
  r = render.render({ width = 120, status = "error", tab = "all", now = D.NOW, error = "boom", retry_key = "R" })
  eq(r.lines[5]:find("Failed to load pipelines: boom", 1, true) ~= nil, true)
  r = rendered({ query = "nothing-matches-this" })
  eq(r.lines[5]:find("No pipelines match", 1, true) ~= nil, true)
  eq(#r.selectable, 0)
end

return T
