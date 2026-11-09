-- gg.ui.issues: columns and render (pure; no windows).
local D = require("tests.support.ui_data")
local columns = require("gg.ui.issues.columns")
local model = require("gg.ui.issues.model")
local paginate = require("gg.ui.issues.paginate")
local render = require("gg.ui.issues.render")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function rendered(opts)
  opts = opts or {}
  local issues = opts.issues or D.issues()
  local m = model.build(issues, { tab = opts.tab or "opened", query = opts.query, today = D.TODAY })
  local pages = paginate.paginate(m.blocks, opts.page_size or 50)
  return render.render({
    width = opts.width or 160,
    status = opts.status or "ready",
    tab = opts.tab or "opened",
    model = m,
    page = pages[opts.page or 1],
    truncated = opts.truncated,
    label_hl = opts.label_hl,
  }), m
end

-- the text a mark covers
local function covered(r, mark)
  return r.lines[mark.row + 1]:sub(mark.col + 1, mark.end_col)
end

local function marks_on(r, lnum, hl)
  local out = {}
  for _, m in ipairs(r.marks) do
    if m.row == lnum - 1 and (hl == nil or m.hl == hl) then
      table.insert(out, covered(r, m))
    end
  end
  return out
end

T["columns: full width layout"] = function()
  local c = columns.layout(160)
  eq({ c.edge.col, c.milestone.col, c.mark.col, c.iid.col, c.title.col }, { 0, 2, 30, 32, 38 })
  eq(c.title.width, 57)
  eq({ c.labels.col, c.assignee.col, c.state.col }, { 97, 131, 150 })
  eq(c.state.col + c.state.width, 160)
end

T["columns: narrow windows hide Labels, then Assignee, then shrink the milestone cell"] = function()
  local c = columns.layout(100)
  eq({ c.labels == nil, c.assignee ~= nil, c.milestone.width, c.title.width }, { true, true, 28, 31 })
  c = columns.layout(70)
  eq({ c.labels, c.assignee, c.milestone.width, c.title.width }, { nil, nil, 28, 20 })
  c = columns.layout(69)
  eq({ c.milestone.width, c.title.width }, { 20, 27 })
  c = columns.layout(40)
  eq({ c.milestone.width, c.title.width }, { 20, 20 }) -- title never below 20
end

T["golden: the mockup at width 160"] = function()
  local r = rendered()
  eq(r.lines, {
    "",
    "    Open 9     Closed 3     All 12  ",
    "",
    "  Milestone                     Issue                                                            Labels                            Assignee           State",
    string.rep("─", 160),
    "  —                             #220  Flaky backup job on weekend window                         ~bug ~backup                      @user-lh           ● Open",
    "  —                             #198  Clean up unused container registry tags                    ~chore                            unassigned         ● Open",
    "▎ %2026.11 Patch cycle          #211  WinRM over HTTPS for newly joined hosts                    ~ansible ~windows                 @user-ma           ● Open",
    "▎ due Nov 20 · in 12d           #214  Rotate Terraform state backend credentials                 ~security ~terraform              @user-ma           ● Open",
    "▎ ━━━━━━━━━━ 2/6                #209  Monitoring sensor for pending-reboot state                 ~monitoring                       @user-lh           ● Open",
    "▎                               #205  Document patch-window rollback procedure                   ~docs                             unassigned         ● Open",
    "▎ %2026.12 Cloud migration      #219  Migrate nginx gateway to OCI load balancer                 ~oci ~network                     @user-ma           ● Open",
    "▎ due Dec 18 · in 40d           #218  Wildcard cert renewal via DNS-01 challenge                 ~oci ~dns                         @user-sf           ● Open",
    "▎ ━━━━━━━━━━ 1/4                #216  Terraform module for object storage buckets                ~terraform                        @user-ma           ● Open",
    "▎",
  })
  eq(r.selectable, { 6, 7, 8, 9, 10, 11, 12, 13, 14 })
  eq(r.rows[15].kind, "filler")
  eq({ r.rows[1].kind, r.rows[2].kind, r.rows[3].kind, r.rows[4].kind, r.rows[5].kind }, { "blank", "tabs", "blank", "header", "rule" })
  eq(vim.tbl_map(function(b)
    return { b.first, b.last, b.kind }
  end, r.blocks), { { 6, 6, "top" }, { 7, 7, "top" }, { 8, 11, "milestone" }, { 12, 15, "milestone" } })
end

T["separators are virt_lines after every milestone and after the top-level group"] = function()
  local r = rendered()
  -- none between the two top-level issues (rows 5 and 6, 0-based)
  eq(vim.tbl_map(function(v)
    return v.row
  end, r.virt_lines), { 6, 10, 14 })
  eq(r.virt_lines[2].chunks, { { string.rep("─", 160), "GitlabSeparator" } })
end

T["golden: narrow width hides columns and truncates titles"] = function()
  local r = rendered({ width = 70 })
  eq(r.lines[4], "  Milestone                     Issue                       State")
  eq(r.lines[6], "  —                             #220  Flaky backup job on…  ● Open")
  eq(r.lines[10], "▎ ━━━━━━━━━━ 2/6                #209  Monitoring sensor f…  ● Open")
end

T["short milestone blocks are padded to 4 lines with non-selectable fillers"] = function()
  local r = rendered({ tab = "closed", width = 120 })
  eq(r.lines[7], "▎ %2026.11 Patch cycle          #201  Patch hypervisors                                    @user-ma           ✓ Closed")
  eq(r.lines[9], "▎ ━━━━━━━━━━ 2/6")
  eq(r.lines[10], "▎")
  eq({ r.rows[9].kind, r.rows[10].kind }, { "filler", "filler" })
  eq(r.selectable, { 6, 7, 8 })
  eq(r.blocks[2].last, 10)
end

T["highlights are byte ranges over the right text (multi-byte safe)"] = function()
  local r = rendered({
    label_hl = function(color)
      return "L" .. color
    end,
  })
  eq(marks_on(r, 2, "GitlabTabActive"), { "  Open 9  " })
  eq(marks_on(r, 2, "GitlabTab"), { "  Closed 3  ", "  All 12  " })
  eq(marks_on(r, 6, "GitlabEmpty"), { "—" })
  eq(marks_on(r, 6, "GitlabIid"), { "#220" })
  eq(marks_on(r, 6, "L#f7768e"), { "~bug" })
  eq(marks_on(r, 6, "GitlabIssueTitle"), { "Flaky backup job on weekend window" })
  -- an unassigned issue is dimmed from the IID on
  eq(marks_on(r, 7, "GitlabUnassigned"), { "#198", "Clean up unused container registry tags", "~chore", "unassigned", "● Open" })
  eq(marks_on(r, 7, "GitlabIssueTitle"), {})
  eq(marks_on(r, 8, "GitlabMilestoneEdge"), { "▎" })
  eq(marks_on(r, 8, "GitlabMilestoneName"), { "%2026.11" })
  eq(marks_on(r, 8, "GitlabMilestoneTitle"), { "Patch cycle" })
  eq(marks_on(r, 9, "GitlabDue"), { "due Nov 20 · in 12d" })
  eq(marks_on(r, 10, "GitlabProgressDone"), { "━━━" })
  eq(marks_on(r, 10, "GitlabProgressTodo"), { "━━━━━━━" })
  eq(marks_on(r, 10, "GitlabProgressText"), { " 2/6" })
  eq(marks_on(r, 10, "GitlabStateOpened"), { "● Open" })
  -- every mark sits on UTF-8 character boundaries
  for _, m in ipairs(r.marks) do
    local s = r.lines[m.row + 1]
    eq(m.col < m.end_col and m.end_col <= #s, true)
    for _, b in ipairs({ m.col + 1, m.end_col + 1 }) do
      local byte = s:byte(b)
      eq(byte == nil or byte < 0x80 or byte >= 0xC0, true)
    end
  end
end

T["rows carry the cursor-mark and edge byte columns"] = function()
  local r = rendered()
  local top, ms = r.rows[6], r.rows[8]
  eq(r.lines[6]:sub(top.mark_col + 1, top.mark_col + 2), "  ")
  eq(vim.fn.strdisplaywidth(r.lines[6]:sub(1, top.mark_col)), 30)
  eq(vim.fn.strdisplaywidth(r.lines[8]:sub(1, ms.mark_col)), 30)
  eq(ms.mark_col, top.mark_col) -- "▎" and "—" are both 3 bytes, 1 cell
  eq(ms.edge, { col = 0, end_col = 3 })
  eq(top.edge, nil)
  eq(r.rows[8].issue.iid, 211)
end

T["wide characters keep every column aligned"] = function()
  local issues = D.issues()
  issues[1].title = "日本語のタイトルがとても長い場合のテストです。さらに長くしてみましょう。"
  issues[1].labels = { { name = "ラベル", color = "#123456" }, { name = "averyveryverylonglabelnamethatwontfit", color = "#123456" } }
  issues[1].assignees = { { username = "a" }, { username = "b" }, { username = "c" } }
  local r = rendered({ issues = issues })
  local s = r.lines[6]
  local cols = r.columns
  local function col_of(needle)
    local i = s:find(needle, 1, true)
    return vim.fn.strdisplaywidth(s:sub(1, i - 1))
  end
  eq(col_of("~ラベル"), cols.labels.col)
  eq(col_of("@a +2"), cols.assignee.col)
  eq(col_of("● Open"), cols.state.col)
  eq(s:find("~averyvery", 1, true) ~= nil, true)
  eq(s:find("…", 1, true) ~= nil, true)
end

T["states: loading, error, empty, truncated"] = function()
  local loading = render.render({ width = 100, status = "loading", tab = "opened", loaded = 120 })
  eq(loading.lines[2], "    Open …     Closed …     All …  ")
  eq(loading.lines[6], "  Loading issues… (120)")
  eq(loading.selectable, {})
  local fresh = render.render({ width = 100, status = "loading", tab = "opened" })
  eq(fresh.lines[6], "  Loading issues…")
  local err = render.render({ width = 100, status = "error", tab = "opened", error = "boom\nline", retry_key = "R" })
  eq({ err.lines[6], err.lines[7] }, { "  Failed to load issues: boom line", "  [R] Retry" })
  local no_retry = render.render({ width = 100, status = "error", tab = "opened", error = "x", retry_key = false })
  eq(#no_retry.lines, 6)
  local empty = rendered({ query = "nothing-matches-this" })
  eq(empty.lines[6], "  No issues match")
  eq(rendered({ truncated = 2000 }).lines[2], "    Open 9     Closed 3     All 12    (first 2000)")
end

T["a block continued on the next page repeats the milestone cell"] = function()
  local r = rendered({ page_size = 3, page = 3 })
  eq(vim.startswith(r.lines[6], "▎ %2026.11 Patch cycle"), true)
  eq(r.rows[6].issue.iid, 205)
end

T["bar_cells rounds halves up, clamps"] = function()
  eq(render.bar_cells(2, 6), 3)
  eq(render.bar_cells(1, 4), 3)
  eq(render.bar_cells(0, 0), 0)
  eq(render.bar_cells(6, 6), 10)
  eq(render.bar_cells(2685, 6247), 4)
end

T["no milestones: the Milestone column is left out"] = function()
  local issues = D.issues()
  for _, issue in ipairs(issues) do
    issue.milestone = nil
  end
  local r, m = rendered({ issues = issues })
  eq(m.has_milestones, false)
  local c = r.columns
  eq(c.milestone, nil)
  eq({ c.edge.col, c.mark.col, c.iid.col, c.title.col, c.title.width }, { 0, 2, 4, 10, 85 })
  eq(r.lines[4]:find("Milestone", 1, true), nil)
  eq(vim.startswith(r.lines[4], "    Issue"), true)
  eq(vim.startswith(r.lines[6], "    #220  Flaky backup"), true)
  for _, lnum in ipairs(r.selectable) do
    eq(r.rows[lnum].mark_col, 2)
    eq(r.lines[lnum]:find("—", 1, true), nil)
  end
  -- every issue is top level: one rule after the last
  eq(#r.virt_lines, 1)
  eq(rendered({ issues = issues, query = "nothing-matches-this" }).lines[6], "  No issues match")
  -- one issue with a milestone (in any tab) brings the column back
  issues[1].milestone = D.issues()[3].milestone
  eq(rendered({ issues = issues, tab = "closed" }).columns.milestone ~= nil, true)
end

return T
