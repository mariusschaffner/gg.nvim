-- The merge request review: the diff model, thread placement, positions,
-- the renderers (pure), and the view end to end.
local H = require("tests.helpers")
local X = require("tests.support.detail_data")
local config = require("gg.ui.config")
local confirm = require("gg.ui.components.confirm")
local date = require("gg.ui.lib.date")
local detail = require("gg.ui.detail")
local files_pane = require("gg.ui.detail.review.files")
local gg = require("gg")
local layout = require("gg.ui.components.layout")
local model = require("gg.ui.detail.review.model")
local position = require("gg.ui.detail.review.position")
local render = require("gg.ui.detail.review.render")
local stack = require("gg.ui.components.stack")
local submit = require("gg.ui.detail.review.submit")
local thread_list = require("gg.ui.detail.review.thread_list")
local threads = require("gg.ui.detail.review.threads")
local viewed = require("gg.ui.detail.review.viewed")
local eq = MiniTest.expect.equality

local s
local saved = {}
local notes

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { columns = vim.o.columns, lines = vim.o.lines, notify = vim.notify, utc = date.utc_offset, input = vim.ui.input, select = confirm.select }
      vim.o.columns, vim.o.lines = 170, 50
      date.utc_offset = function()
        return 0
      end
      notes = {}
      vim.notify = function(msg, level)
        table.insert(notes, { msg, level })
      end
      viewed.path = vim.fn.tempname()
    end,
    post_case = function()
      vim.cmd("stopinsert")
      if s and not s:is_closed() then
        s:close()
      end
      s = nil
      vim.notify, vim.ui.input, confirm.select = saved.notify, saved.input, saved.select
      date.utc_offset = saved.utc
      vim.o.columns, vim.o.lines = saved.columns, saved.lines
      os.remove(viewed.path)
      viewed.path = nil
      config.setup()
      H.reset()
    end,
  },
})

local DIFF = "@@ -3,4 +3,5 @@ local function f()\n a\n-b\n+B\n+C\n d\n e\n@@ -20,2 +21,2 @@\n x\n-y\n+Y\n"

local function raw_file(path, diff, extra)
  return vim.tbl_extend("force", { old_path = path, new_path = path, diff = diff, new_file = false, renamed_file = false, deleted_file = false }, extra or {})
end

local function texts(rows)
  return vim.tbl_map(function(r)
    if r.kind == "gap" then
      return ("gap%d:%s"):format(r.gap, tostring(r.count))
    elseif r.kind == "hunk" then
      return "hunk" .. r.hunk
    end
    return ("%s %s/%s %s"):format(r.type, tostring(r.old_line), tostring(r.new_line), r.text)
  end, rows)
end

-- ------------------------------------------------------------------ pure

T["model: files with counts and status"] = function()
  local list = model.files({
    raw_file("src/a.lua", DIFF),
    raw_file("new.lua", "@@ -0,0 +1,2 @@\n+x\n+y\n", { new_file = true }),
    raw_file("big.lua", "", { too_large = true }),
    raw_file("moved.lua", "", { renamed_file = true, old_path = "old.lua" }),
  })
  eq({ list[1].status, list[1].additions, list[1].deletions, #list[1].hunks }, { "M", 3, 2, 2 })
  eq({ list[2].status, list[2].additions, list[2].deletions }, { "A", 2, 0 })
  eq({ list[3].unavailable, list[3].additions }, { "too large", nil })
  eq({ list[4].status, list[4].unavailable, list[4].old_path, list[4].path }, { "R", "no text changes", "old.lua", "moved.lua" })
  eq({ model.totals(list) }, { 5, 2 })
end

T["model: rows with gaps; a gap expands from the file's content"] = function()
  local f = model.file(raw_file("src/a.lua", DIFF), 1)
  eq(texts(model.rows(f)), {
    "gap1:2", "hunk1", "context 3/3 a", "delete 4/nil b", "add nil/4 B", "add nil/5 C", "context 5/6 d", "context 6/7 e",
    "gap2:13", "hunk2", "context 20/21 x", "delete 21/nil y", "add nil/22 Y", "gap3:nil",
  })
  local content = {}
  for i = 1, 24 do
    content[i] = "L" .. i
  end
  local rows = model.rows(f, { content = content, expanded = { [1] = true, [3] = true } })
  eq(vim.list_slice(texts(rows), 1, 3), { "context 1/1 L1", "context 2/2 L2", "context 3/3 a" })
  eq(vim.list_slice(texts(rows), #rows - 2), { "add nil/22 Y", "context 22/23 L23", "context 23/24 L24" })
  eq(rows[1].gap, 1)
  -- old line numbers follow the offset of the hunks before
  local all = model.rows(f, { content = content, expanded = model.all_gaps(f) })
  eq(texts(all)[9], "context 7/8 L8")
  -- the content ends with the last hunk: no gap after it
  eq(texts(model.rows(f, { content = vim.list_slice(content, 1, 22) }))[14], nil)
  -- an added file is its diff: no gaps
  local added = model.file(raw_file("n.lua", "@@ -0,0 +1 @@\n+x\n", { new_file = true }), 1)
  eq(texts(model.rows(added)), { "hunk1", "add nil/1 x" })
  eq(model.max_line(model.rows(f)), 23)
end

local function note(id, body, pos, extra)
  return vim.tbl_extend("force", { id = id, body = body, system = false, author = { username = "user-2", name = "Bea Other" }, created_at = "2026-11-10T10:00:00Z", position = pos }, extra or {})
end

local function pos(extra)
  return vim.tbl_extend("force", { old_path = "src/a.lua", new_path = "src/a.lua", position_type = "text" }, extra)
end

T["threads: discussions and drafts of a file, placed on its rows"] = function()
  local f = model.file(raw_file("src/a.lua", DIFF), 1)
  local discussions = {
    { id = "d1", resolvable = true, resolved = false, notes = { note(1, "on B", pos({ new_line = 4 })), note(2, "reply") } },
    { id = "d2", resolvable = true, resolved = true, notes = { note(3, "on removed b", pos({ old_line = 4 })) } },
    { id = "d3", notes = { note(4, "elsewhere", pos({ new_path = "other.lua", old_path = "other.lua", new_line = 1 })) } },
    { id = "d4", notes = { note(5, "the file", pos({ position_type = "file" })) } },
    { id = "d5", notes = { note(6, "far away", pos({ old_line = 12, new_line = 13 })) } },
    { id = "d6", notes = { note(7, "gone", pos({ new_line = 400 }), { outdated = true }) } },
    { id = "d7", notes = { note(8, "sys", nil, { system = true }) } },
    { id = "d8", notes = { note(9, "range", pos({ new_line = 5, line_range = { start = { new_line = 4 }, ["end"] = { new_line = 5 } } })) } },
  }
  local drafts = {
    { id = 20, note = "draft reply", discussion_id = "d1", resolve_discussion = true },
    { id = 21, note = "draft on Y", position = pos({ new_line = 22 }) },
    { id = 22, note = "general" },
    { id = 23, note = "other file", position = pos({ new_path = "other.lua", old_path = "other.lua", new_line = 1 }) },
  }
  local list = threads.for_file(f, discussions, drafts, { me = { username = "user-1" }, folded = { d1 = true } })
  eq(vim.tbl_map(function(t)
    return t.id
  end, list), { "d1", "d2", "d4", "d5", "d6", "d8", "draft:21" })
  eq({ #list[1].replies, list[1].replies[2].pending, list[1].replies[2].draft_id, list[1].folded }, { 2, true, 20, true })
  eq({ list[3].file_level, list[5].outdated, list[6].context, list[7].pending }, { true, true, "lines 4–5", true })
  local rows = model.rows(f)
  local placed = threads.place(rows, list)
  eq(vim.tbl_map(function(t)
    return t.id
  end, placed.top), { "d4" })
  -- the file's length is not known: a line beyond the diff counts as below it
  eq({ placed.at[14][1].id, placed.at[14][1].context }, { "d6", "line 400" })
  eq(placed.at[5][1].id, "d1") -- add nil/4 B
  eq(placed.at[4][1].id, "d2") -- delete 4/nil b
  eq(placed.at[6][1].id, "d8") -- the last line of the range
  eq({ placed.at[9][1].id, placed.at[9][1].context }, { "d5", "line 13" }) -- inside gap 2
  eq(placed.at[13][1].id, "draft:21")
  local c = threads.counts({ f }, discussions, drafts)
  eq({ c.threads, c.unresolved, c.pending }, { 6, 1, 4 })
  eq(c.files["src/a.lua"], { threads = 6, pending = 2 })
end

T["position: added, removed, unchanged lines, ranges, the file"] = function()
  local f = model.file(raw_file("b.lua", DIFF, { old_path = "a.lua", renamed_file = true }), 1)
  local add = { kind = "line", type = "add", new_line = 4, index = 5 }
  local del = { kind = "line", type = "delete", old_line = 4, index = 4 }
  local ctx = { kind = "line", type = "context", old_line = 5, new_line = 6, index = 7 }
  eq(position.lines(f, add, add), { new_path = "b.lua", old_path = "a.lua", position_type = "text", new_line = 4 })
  eq(position.lines(f, del, del), { new_path = "b.lua", old_path = "a.lua", position_type = "text", old_line = 4 })
  local p = position.lines(f, ctx, del) -- given backwards
  eq({ p.old_line, p.new_line }, { 5, 6 })
  eq({ p.line_range.start.type, p.line_range.start.old_line, p.line_range["end"].type }, { "old", 4, nil })
  eq(p.line_range.start.line_code:match("^%x+_4_0$") ~= nil, true)
  eq({ position.lines(f, { kind = "gap" }, add) }, { nil, "Comments go on lines of the diff" })
  eq(position.file(f).position_type, "file")
  eq({ position.label(f, position.lines(f, add, add)), position.label(f, p), position.label(f, position.file(f)) }, { "b.lua:4", "b.lua:4–6", "b.lua · file" })
end

T["render: gutter, tints, gaps, threads under their line"] = function()
  local f = model.file(raw_file("src/a.lua", DIFF), 1)
  local rows = model.rows(f)
  local list = threads.for_file(f, { { id = "d1", resolvable = true, resolved = false, notes = { note(1, "on B", pos({ new_line = 4 })) } } }, { { id = 21, note = "draft on Y", position = pos({ new_line = 22 }) } }, { me = { username = "user-1", name = "Ann Example" } })
  local d = render.render({ width = 100, status = "ready", file = f, rows = rows, placed = threads.place(rows, list), me = "user-1", utc_offset = 0, keys = { fold = "za" } })
  eq(d.lines[1], "         ⋯ 2 unchanged lines · [za] expand")
  eq(d.lines[2], "         @@ -3,4 +3,5 @@ local function f()")
  eq(d.lines[3], "   3   3   a")
  eq(d.lines[4], "   4     - b")
  eq(d.lines[5], "       4 + B")
  eq(d.lines[6]:find("╭ BO Bea Other  ◷ unresolved thread ─", 1, true) ~= nil, true)
  eq(vim.endswith(d.lines[6], "─ 10:00 ─╮"), true)
  eq(d.lines[7]:find("│ on B", 1, true) ~= nil, true)
  eq(d.lines[8]:find("╰─", 1, true) ~= nil, true)
  eq(d.rows[5], { kind = "line", type = "add", new_line = 4, index = 5, col = 11 })
  eq(d.lines[5]:sub(d.rows[5].col + 1), "B")
  eq({ d.rows[6].kind, d.rows[6].thread, d.rows[6].note }, { "comment", "d1", 1 })
  eq(d.rows[1], { kind = "fold", gap = 1, index = 1 })
  local tints = {}
  for _, m in ipairs(d.marks) do
    if m.hl_eol then
      eq({ m.col, m.end_row, m.end_col, m.priority }, { 0, m.row + 1, 0, 10 })
      tints[m.row + 1] = m.hl
    end
  end
  eq(d.line_hls, {})
  eq({ tints[3], tints[4], tints[5] }, { nil, "GitlabDiffDeleteLine", "GitlabDiffAddLine" })
  local last
  for i, l in ipairs(d.lines) do
    if l:find("◷ pending", 1, true) then
      last = i
    end
  end
  eq(d.lines[last]:find("AE Ann Example  you ─", 1, true) ~= nil, true)
  eq(d.lines[last - 1], "      22 + Y")
  eq(d.lines[#d.lines], "         ⋯ unchanged lines below · [za] expand")
  -- states
  eq(render.render({ width = 80, status = "loading" }).lines, { " Loading the changes…" })
  eq(render.render({ width = 80, status = "error", error = "boom" }).lines, { " boom" })
  eq(render.render({ width = 80, status = "ready" }).lines, { " No changes." })
  local big = model.file(raw_file("big.lua", "", { too_large = true }), 1)
  local bd = render.render({ width = 80, status = "ready", file = big, keys = { fold = "za" } })
  eq(bd.lines, { " The diff is not shown: too large. · [za] load" })
  eq(bd.rows[1], { kind = "unavailable", loadable = true })
end

T["intraline: the characters that differ between a removed and an added line"] = function()
  local intraline = require("gg.ui.detail.review.intraline")
  eq({ intraline.ranges("foo(a)", "foo(a, b)") }, { {}, { { 5, 8 } } })
  eq({ intraline.ranges("timeout = 10", "timeout = 30") }, { { { 10, 11 } }, { { 10, 11 } } })
  -- multi-byte characters: byte ranges
  eq({ intraline.ranges("naïve é", "naïve ü") }, { { { 7, 9 } }, { { 7, 9 } } })
  -- equal, empty or nothing in common: no marks
  eq({ intraline.ranges("same", "same") }, {})
  eq({ intraline.ranges("", "x") }, {})
  eq({ intraline.ranges("abcdef", "uvwxyz") }, {})
  -- pairs: the n-th removed line with the n-th added line of a run
  local rows = {
    { kind = "line", type = "context", text = "a" },
    { kind = "line", type = "delete", text = "x = 1" },
    { kind = "line", type = "delete", text = "gone" },
    { kind = "line", type = "add", text = "x = 2" },
    { kind = "line", type = "context", text = "b" },
    { kind = "line", type = "add", text = "new" },
  }
  eq(intraline.rows(rows), { [2] = { { 4, 5 } }, [4] = { { 4, 5 } } })
  -- drawn over the code, after the gutter
  local f = model.file(raw_file("a.lua", "@@ -1 +1 @@\n-x = 1\n+x = 2\n"), 1)
  local d = render.render({ width = 80, status = "ready", file = f, rows = model.rows(f) })
  local marks = vim.tbl_filter(function(m)
    return m.hl == "GitlabDiffDeleteText" or m.hl == "GitlabDiffAddText"
  end, d.marks)
  eq(marks, {
    { row = 1, col = 15, end_col = 16, hl = "GitlabDiffDeleteText", priority = 110 },
    { row = 2, col = 15, end_col = 16, hl = "GitlabDiffAddText", priority = 110 },
  })
  eq(d.lines[2]:sub(16, 16), "1")
end

T["files pane: a tree with marks and counts; directories close"] = function()
  local list = files_pane.sorted(model.files({
    raw_file("README.md", "@@ -1 +0,0 @@\n-x\n", { deleted_file = true }),
    raw_file("lua/gg/ui/b.lua", "@@ -0,0 +1 @@\n+x\n", { new_file = true }),
    raw_file("lua/gg/ui/a.lua", DIFF),
    raw_file("lua/gg/core/task.lua", DIFF),
    raw_file("tests/t.lua", DIFF),
  }))
  -- directories first, by name; the files are renumbered in that order
  eq(vim.tbl_map(function(f)
    return f.index .. ":" .. f.path
  end, list), { "1:lua/gg/core/task.lua", "2:lua/gg/ui/a.lua", "3:lua/gg/ui/b.lua", "4:tests/t.lua", "5:README.md" })
  local input = { width = 32, status = "ready", files = list, current = 2, viewed = { ["lua/gg/ui/b.lua"] = true }, counts = { ["lua/gg/ui/a.lua"] = { threads = 1, pending = 2 } } }
  local d = files_pane.render(input)
  eq(d.lines[1], " ▾ lua/gg/") -- a directory holding one directory is joined with it
  eq(d.lines[2], "   ▾ core/")
  eq(vim.startswith(d.lines[3], "       task.lua"), true)
  eq(d.lines[4], "   ▾ ui/")
  eq(vim.startswith(d.lines[5], "     ▸ a.lua"), true)
  eq(vim.endswith(d.lines[5], "◷2 💬1 +3 −2"), true)
  eq(vim.startswith(d.lines[6], "     ✓ b.lua"), true)
  eq(vim.endswith(d.lines[6], "+1 A"), true)
  eq(d.lines[7], " ▾ tests/")
  eq(vim.startswith(d.lines[9], "   README.md"), true)
  eq(vim.endswith(d.lines[9], "−1 D"), true)
  eq(d.rows[5], { kind = "file", index = 2, path = "lua/gg/ui/a.lua" })
  eq(d.rows[4], { kind = "dir", path = "lua/gg/ui/" })
  eq({ files_pane.lnum_of(d, 5), files_pane.lnum_of(d, 9) }, { 9, nil })
  for _, l in ipairs(d.lines) do
    eq(vim.fn.strdisplaywidth(l) <= 32, true)
  end
  input.collapsed = { ["lua/gg/"] = true }
  local c = files_pane.render(input)
  eq({ c.lines[1], c.lines[2], #c.lines }, { " ▸ lua/gg/", " ▾ tests/", 4 })
  eq(files_pane.render({ width = 32, status = "loading" }).lines, { " Loading…" })
end

T["threads pane: every thread by file, in line order"] = function()
  local fa = model.file(raw_file("src/a.lua", DIFF), 1)
  local fb = model.file(raw_file("src/b.lua", DIFF), 2)
  local on_b = { old_path = "src/b.lua", new_path = "src/b.lua", position_type = "text", new_line = 4 }
  local groups, count = thread_list.groups({ fa, fb }, {
    { id = "d1", resolvable = true, resolved = false, notes = { note(1, "later line", pos({ new_line = 22 })) } },
    { id = "d2", resolvable = true, resolved = true, notes = { note(2, "done\nmore", pos({ old_line = 4 })) } },
    { id = "d3", notes = { note(3, "the file", pos({ position_type = "file" })) } },
    { id = "d4", resolvable = true, resolved = false, notes = { note(4, "on b", on_b) } },
  }, { { id = 9, note = "mine", position = pos({ new_line = 5 }) }, { id = 10, note = "re", discussion_id = "d4" } }, { me = { username = "user-1" } })
  eq(count, 5)
  local d = thread_list.render({ width = 32, status = "ready", groups = groups })
  eq(d.lines, {
    " a.lua",
    " file • the file",
    "    4 ✓ done",
    "    5 ◷ mine",
    "   22 ● later line",
    " b.lua",
    "    4 ◷ on b",
  })
  eq(d.rows[1], { kind = "file", index = 1 })
  eq(d.rows[5], { kind = "thread", index = 1, thread = "d1" })
  eq(d.rows[7], { kind = "thread", index = 2, thread = "d4" })
  eq(thread_list.render({ width = 32, status = "ready", groups = {} }).lines, { " No threads." })
end

T["submit: actions and the pending list"] = function()
  eq(submit.title(2), "Submit review · 2 pending comments")
  eq(vim.tbl_map(function(a)
    return a.key
  end, submit.actions(0)), { "comment", "approve", "changes" })
  local a = submit.actions(1)
  eq(vim.tbl_map(function(x)
    return x.key
  end, a), { "show", "comment", "approve", "changes", "discard" })
  eq({ a[2].reviewer_state, a[3].approve, a[3].reviewer_state, a[4].reviewer_state }, { "reviewed", true, nil, "requested_changes" })
  local entries = submit.pending({
    { id = 1, note = "first\nsecond", position = pos({ new_line = 4 }) },
    { id = 2, note = "re", discussion_id = "d1" },
    { id = 3, note = "overall" },
  }, { { id = "d1", notes = { note(1, "x", pos({ old_line = 9 })) } } })
  eq(entries[1], { text = "src/a.lua:4  first", path = "src/a.lua", note = "draft:1" })
  eq(entries[2].text, "↩ src/a.lua:9  re")
  eq({ entries[3].text, entries[3].path }, { "general  overall", nil })
end

T["viewed: kept per merge request and head"] = function()
  local key = viewed.key("gitlab.example.com", "g/p", 3, "abc")
  eq(key, "gitlab.example.com/g/p!3@abc")
  eq(viewed.load(key), {})
  eq(viewed.save(key, { ["a.lua"] = true, ["b.lua"] = false }, 10), true)
  eq(viewed.load(key), { ["a.lua"] = true })
  eq(viewed.load(viewed.key("gitlab.example.com", "g/p", 3, "def")), {})
  viewed.save(key, {})
  eq(viewed.load(key), {})
end

T["layout: the sidebar on the left"] = function()
  local r = layout.detail({ header_h = 3, sidebar = true, left = true, area = { columns = 120, lines = 40 } })
  eq(r.sidebar, { row = 6, col = 0, width = 32, height = 32 })
  eq(r.content, { row = 6, col = 35, width = 83, height = 32 })
  eq(layout.detail({ header_h = 3, sidebar = true, left = true, area = { columns = 90, lines = 40 } }).sidebar, nil)
  -- no gap under the header; the side pane split in two boxes
  local tight = layout.detail({ header_h = 3, sidebar = true, left = true, gap = 0, area = { columns = 120, lines = 40 } })
  eq({ tight.content.row, tight.content.height }, { 5, 33 })
  local upper, lower = layout.split(tight.sidebar)
  eq(upper, { row = 5, col = 0, width = 32, height = 21 })
  eq(lower, { row = 28, col = 0, width = 32, height = 10 })
  eq({ layout.split({ row = 0, col = 0, width = 32, height = 6 }) }, { { row = 0, col = 0, width = 32, height = 6 } })
end

-- ------------------------------------------------------------------ view

local BASE = "/api/v4/projects/" .. X.ENC .. "/merge_requests/" .. X.MR_IID
local HEAD = "fc1a118b066a56deac5b26a27e336932a0356c0f"

local function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "x", false)
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function last_note()
  return notes[#notes] and notes[#notes][1]
end

local function chunks_text(c)
  if type(c) ~= "table" then
    return c
  end
  return table.concat(vim.tbl_map(function(x)
    return x[1]
  end, c))
end

local function rest_note(id, body, p, extra)
  return vim.tbl_extend("force", {
    id = id,
    type = "DiffNote",
    body = body,
    author = X.rest_user(2, "Bea Other"),
    created_at = "2026-11-10T10:00:00Z",
    updated_at = "2026-11-10T10:00:00Z",
    system = false,
    resolvable = true,
    resolved = false,
    position = p,
  }, extra or {})
end

local function rest_pos(extra)
  return vim.tbl_extend("force", { base_sha = "b", start_sha = "b", head_sha = HEAD, old_path = "src/a.lua", new_path = "src/a.lua", position_type = "text" }, extra)
end

local drafts_fx

-- what the drafts list answers from now on
local function set_drafts(list)
  drafts_fx.response.body = list
end

local function responses()
  return {
    X.mr_get({ state = "opened", mergedAt = vim.NIL }, { ["repeat"] = true }),
    X.current_user(),
    {
      ["repeat"] = true,
      request = { method = "GET", path = BASE .. "/diffs" },
      response = { headers = { ["x-next-page"] = "" }, body = { raw_file("src/a.lua", DIFF), raw_file("src/b.lua", "@@ -0,0 +1 @@\n+w\n", { new_file = true }) } },
    },
    {
      ["repeat"] = true,
      request = { method = "GET", path = BASE .. "/discussions" },
      response = { body = { { id = "d1", individual_note = false, notes = { rest_note(501, "Why B?", rest_pos({ new_line = 4 })) } } } },
    },
  }
end

local function open(extra)
  local fake = H.fake()
  fake:add(responses())
  fake:add(extra or {})
  -- the drafts list follows what was created
  fake:add({ ["repeat"] = true, request = { method = "GET", path = BASE .. "/draft_notes" }, response = { body = {} } })
  drafts_fx = fake._fixtures[#fake._fixtures]
  s = stack.new()
  detail.review({ stack = s, cfg = config.get(), host = X.HOST, project = X.PROJECT, today = X.TODAY }, { iid = X.MR_IID })
  local g = s:top().group
  H.wait_for(function()
    local c = lines(g.members.content.buf)
    return c[3] == "   3   3   a" and table.concat(c, "\n"):find("Why B?", 1, true) ~= nil
  end)
  return g, fake, g.members.content.win
end

local function composer_set(text)
  H.wait_for(function()
    return vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).zindex == 150
  end)
  vim.cmd("stopinsert")
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(w), 0, -1, false, vim.split(text, "\n"))
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = vim.api.nvim_win_get_buf(w) })
  return w
end

local function row_of(win, pat)
  for i, l in ipairs(lines(vim.api.nvim_win_get_buf(win))) do
    if l:find(pat, 1, true) then
      return i
    end
  end
end

local function request(fake, method, path)
  local found
  for _, r in ipairs(fake:requests()) do
    if r.method == method and r.path == path then
      found = r
    end
  end
  return found
end

T["view: files on the left, the diff with its thread, border labels"] = function()
  local g, _, win = open()
  local c = lines(g.members.content.buf)
  eq(c[1], "         ⋯ 2 unchanged lines · [za] expand")
  eq(c[5], "       4 + B")
  eq(c[6]:find("Bea Other", 1, true) ~= nil, true)
  local side = lines(g.members.sidebar.buf)
  eq(side[1], "")
  eq(side[2], " ▾ src/")
  eq(vim.startswith(side[3], "   ▸ a.lua"), true)
  eq(vim.endswith(side[3], "💬1 +3 −2"), true)
  eq(vim.endswith(side[4], "+1 A"), true)
  -- the threads pane below the files
  local tp = g.members.threads
  eq(lines(tp.buf), { "", " a.lua", "    4 ● Why B?" })
  eq(chunks_text(vim.api.nvim_win_get_config(tp.win).title), " Threads 1 ")
  eq(chunks_text(vim.api.nvim_win_get_config(tp.win).footer), " [<CR>] Go to ")
  local sp, tpos = vim.api.nvim_win_get_position(g.members.sidebar.win), vim.api.nvim_win_get_position(tp.win)
  eq(tpos[1], sp[1] + vim.api.nvim_win_get_height(g.members.sidebar.win) + 2)
  eq(tpos[1] + vim.api.nvim_win_get_height(tp.win), vim.api.nvim_win_get_position(win)[1] + vim.api.nvim_win_get_height(win))
  -- no empty row between the header and the boxes below it
  eq(vim.api.nvim_win_get_position(win)[1], vim.api.nvim_win_get_height(g.members.header.win) + 2)
  -- the sidebar sits left of the content
  eq(vim.api.nvim_win_get_position(g.members.sidebar.win)[2] < vim.api.nvim_win_get_position(win)[2], true)
  local cfg = vim.api.nvim_win_get_config(win)
  local title, footer = chunks_text(cfg.title), chunks_text(cfg.footer)
  eq(vim.startswith(title, " src/a.lua ─"), true)
  eq(title:find("+3 −2 · M · 1/2 ", 1, true) ~= nil, true)
  eq(vim.startswith(footer, " [i] Comment • [x] Viewed • []f] Next file • [gs] Submit "), true)
  eq(chunks_text(vim.api.nvim_win_get_config(g.members.sidebar.win).title), " Files 2 ")
  eq(chunks_text(vim.api.nvim_win_get_config(g.members.sidebar.win).footer), " [<CR>] Open • [i] Comment ")
  local head = chunks_text(vim.api.nvim_win_get_config(g.members.header.win).title)
  eq(vim.startswith(head, " merge requests › !88 › review "), true)
  eq(head:find("0/2 viewed · 1 thread ", 1, true) ~= nil, true)
  eq(vim.startswith(lines(g.members.header.buf)[2], "  ● Open  Rotate Terraform state backend credentials !88"), true)
  -- the tint of a changed line lies below the text's own highlights: an
  -- edge-to-edge mark of low priority, not a line highlight group (which
  -- would paint over the syntax colours and the marked characters)
  local tint, line_groups = nil, 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(g.members.content.buf, vim.api.nvim_create_namespace("gg.ui.detail"), { 3, 0 }, { 3, -1 }, { details = true })) do
    if m[4].line_hl_group then
      line_groups = line_groups + 1
    elseif m[4].hl_eol then
      tint = { m[4].hl_group, m[4].priority, m[4].end_row }
    end
  end
  eq({ tint, line_groups }, { { "GitlabDiffDeleteLine", 10, 4 }, 0 })
  -- the cursor starts on the first change
  eq(vim.api.nvim_win_get_cursor(win)[1], 4)
  eq(vim.api.nvim_get_current_win(), win)
end

T["view: files, hunks and threads are stepped through; x marks viewed"] = function()
  local g, _, win = open()
  keys("]h")
  eq(lines(g.members.content.buf)[vim.api.nvim_win_get_cursor(win)[1]], "  21     - y")
  keys("]h")
  eq(vim.api.nvim_win_get_cursor(win)[1], 4) -- wraps
  keys("]c")
  eq(vim.api.nvim_win_get_cursor(win)[1], 6)
  keys("]f")
  eq(lines(g.members.content.buf), { "         @@ -0,0 +1 @@", "       1 + w" })
  eq(vim.startswith(chunks_text(vim.api.nvim_win_get_config(win).title), " src/b.lua ─"), true)
  eq(vim.api.nvim_win_get_cursor(g.members.sidebar.win)[1], 4)
  keys("]f")
  eq(lines(g.members.content.buf)[3], "   3   3   a")
  -- viewed: marked, stored, on to the next file not viewed
  keys("x")
  eq(lines(g.members.content.buf)[2], "       1 + w")
  eq(vim.startswith(lines(g.members.sidebar.buf)[3], "   ✓ a.lua"), true)
  eq(viewed.load(viewed.key(X.HOST, X.PROJECT, X.MR_IID, HEAD)), { ["src/a.lua"] = true })
  eq(chunks_text(vim.api.nvim_win_get_config(g.members.header.win).title):find("1/2 viewed", 1, true) ~= nil, true)
  -- the files pane: <Tab> focuses it, moving shows the file, <CR> goes back
  keys("<Tab>")
  eq(vim.api.nvim_get_current_win(), g.members.sidebar.win)
  vim.api.nvim_win_set_cursor(g.members.sidebar.win, { 3, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = g.members.sidebar.buf })
  eq(lines(g.members.content.buf)[3], "   3   3   a")
  keys("<CR>")
  eq(vim.api.nvim_get_current_win(), win)
  -- a directory closes and opens
  keys("<Tab>")
  vim.api.nvim_win_set_cursor(g.members.sidebar.win, { 2, 0 })
  keys("<CR>")
  eq(lines(g.members.sidebar.buf), { "", " ▸ src/" })
  keys("za")
  eq(#lines(g.members.sidebar.buf), 4)
  -- <Tab> again: the threads pane; <CR> on a thread jumps to it
  keys("]f")
  eq(lines(g.members.content.buf)[2], "       1 + w")
  keys("<Tab>")
  eq(vim.api.nvim_get_current_win(), g.members.threads.win)
  vim.api.nvim_win_set_cursor(g.members.threads.win, { 3, 0 })
  keys("<CR>")
  eq(vim.api.nvim_get_current_win(), win)
  eq(lines(g.members.content.buf)[vim.api.nvim_win_get_cursor(win)[1]]:find("Bea Other", 1, true) ~= nil, true)
  keys("<Tab><Tab><Tab>")
  eq(vim.api.nvim_get_current_win(), win)
  -- q goes back
  keys("q")
  eq(s:is_closed(), true)
end

T["view: za expands a gap from the file's content"] = function()
  local body = {}
  for i = 1, 24 do
    body[i] = "L" .. i
  end
  local g, fake, win = open({
    {
      request = { method = "GET", path = "/api/v4/projects/45049979/repository/files/src%2Fa.lua/raw", query = { ref = HEAD } },
      response = { headers = { ["Content-Type"] = "text/plain" }, body = table.concat(body, "\n") .. "\n" },
    },
  })
  os.remove(vim.fn.stdpath("cache") .. "/gg/files/" .. HEAD .. "/" .. vim.fn.sha256("src/a.lua"))
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  keys("za")
  H.wait_for(function()
    return lines(g.members.content.buf)[1] == "   1   1   L1"
  end)
  eq(lines(g.members.content.buf)[2], "   2   2   L2")
  eq(lines(g.members.content.buf)[3], "   3   3   a")
  eq(request(fake, "GET", "/api/v4/projects/45049979/repository/files/src%2Fa.lua/raw") ~= nil, true)
  -- za on one of its lines folds it again
  keys("za")
  eq(lines(g.members.content.buf)[1], "         ⋯ 2 unchanged lines · [za] expand")
  -- zA: the whole file (the content is there already)
  keys("zA")
  local c = lines(g.members.content.buf)
  eq(c[1], "   1   1   L1")
  eq(c[#c], "  23  24   L24")
  keys("zA")
  eq(lines(g.members.content.buf)[1], "         ⋯ 2 unchanged lines · [za] expand")
end

T["view: a diff GitLab did not send is computed from both sides; code is coloured"] = function()
  local BASE_SHA = "1ab692e5cfc809947e1852c77e0692e09b2eacde"
  local fake = H.fake()
  local r = responses()
  r[3].response.body = { raw_file("big.lua", "", { too_large = true }) }
  fake:add(r)
  fake:add({
    { ["repeat"] = true, request = { method = "GET", path = BASE .. "/draft_notes" }, response = { body = {} } },
    { request = { method = "GET", path = "/api/v4/projects/" .. X.ENC .. "/repository/files/big.lua/raw", query = { ref = BASE_SHA } }, response = { body = "local a = 1\nlocal b = 2\n" } },
    { request = { method = "GET", path = "/api/v4/projects/45049979/repository/files/big.lua/raw", query = { ref = HEAD } }, response = { body = "local a = 1\nlocal b = 3\n" } },
  })
  for _, sha in ipairs({ BASE_SHA, HEAD }) do
    os.remove(vim.fn.stdpath("cache") .. "/gg/files/" .. sha .. "/" .. vim.fn.sha256("big.lua"))
  end
  s = stack.new()
  detail.review({ stack = s, cfg = config.get(), host = X.HOST, project = X.PROJECT, today = X.TODAY }, { iid = X.MR_IID })
  local g = s:top().group
  local buf = g.members.content.buf
  H.wait_for(function()
    return lines(buf)[1] == " The diff is not shown: too large. · [za] load"
  end)
  eq(vim.endswith(lines(g.members.sidebar.buf)[2], "±?"), true)
  keys("za")
  H.wait_for(function()
    return lines(buf)[3] == "   2     - local b = 2"
  end)
  eq(lines(buf), { "         @@ -1,2 +1,2 @@", "   1   1   local a = 1", "   2     - local b = 2", "       2 + local b = 3" })
  eq(vim.endswith(lines(g.members.sidebar.buf)[2], "+1 −1"), true)
  -- treesitter colours over the code (the Lua parser ships with Neovim)
  local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("gg.ui.review.syntax"), 0, -1, { details = true })
  local keyword
  for _, m in ipairs(marks) do
    if m[2] == 1 and m[3] == 11 and m[4].hl_group == "@keyword.lua" then
      keyword = m[4].end_col
    end
  end
  eq(keyword, 16)
end

T["view: i adds a pending comment on a line, on a range, on the file"] = function()
  local g, fake, win = open({
    {
      ["repeat"] = true,
      request = { method = "POST", path = BASE .. "/draft_notes" },
      response = { status = 201, body = { id = 31, note = "x" } },
    },
  })
  vim.api.nvim_win_set_cursor(win, { 5, 0 })
  keys("j") -- onto the thread: back to the line
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  keys("i")
  local cw = composer_set("Keep b?")
  local cfg = vim.api.nvim_win_get_config(cw)
  eq(cfg.title[1][1], " Comment · a.lua:4 ")
  eq(chunks_text(cfg.footer), " [<C-s>] Add to review • [<C-p>] Post now • [<Esc>] Cancel ● unsaved ")
  set_drafts({ { id = 31, note = "Keep b?", author_id = 1, position = rest_pos({ old_line = 4 }) } })
  keys("<C-s>")
  H.wait_for(function()
    return last_note() == "gg.ui: Comment added to the review" and row_of(win, "Keep b?") ~= nil
  end)
  local post = request(fake, "POST", BASE .. "/draft_notes")
  eq(post.json.note, "Keep b?")
  eq(post.json.position, { old_path = "src/a.lua", new_path = "src/a.lua", position_type = "text", old_line = 4, base_sha = "1ab692e5cfc809947e1852c77e0692e09b2eacde", start_sha = "1ab692e5cfc809947e1852c77e0692e09b2eacde", head_sha = HEAD })
  local c = lines(g.members.content.buf)
  eq(c[4], "   4     - b")
  eq(c[5]:find("╭ AE Ann Example  you ─", 1, true) ~= nil, true)
  eq(vim.endswith(c[5], "─ ◷ pending ─╮"), true)
  eq(vim.api.nvim_win_get_cursor(win)[1], 5) -- on the new comment
  eq(vim.endswith(chunks_text(vim.api.nvim_win_get_config(win).footer), " 1 pending ─"), true)
  eq(vim.endswith(lines(g.members.sidebar.buf)[3], "◷1 💬1 +3 −2"), true)
  -- a range: the visual selection
  vim.api.nvim_win_set_cursor(win, { row_of(win, "   5   6   d"), 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("Vji", true, false, true), "x", false)
  cw = composer_set("These two")
  eq(vim.api.nvim_win_get_config(cw).title[1][1], " Comment · a.lua:6–7 ")
  keys("<Esc>")
  -- hunk headers and gaps take no comment
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  keys("i")
  eq(last_note(), "gg.ui: Comments go on lines of the diff ([i] in the files pane comments on the whole file)")
  -- the whole file, from the files pane
  keys("<Tab>")
  vim.api.nvim_win_set_cursor(g.members.sidebar.win, { 3, 0 })
  keys("i")
  cw = composer_set("Whole file")
  eq(vim.api.nvim_win_get_config(cw).title[1][1], " Comment · a.lua · file ")
  keys("<C-s>")
  H.wait_for(function()
    return (request(fake, "POST", BASE .. "/draft_notes").json.position or {}).position_type == "file"
  end)
end

T["view: gc replies into the review; <C-p> posts at once; gE and gD on a pending comment"] = function()
  local g, fake, win = open({
    { ["repeat"] = true, request = { method = "POST", path = BASE .. "/draft_notes" }, response = { status = 201, body = { id = 32, note = "x" } } },
    { request = { method = "POST", path = BASE .. "/discussions/d1/notes" }, response = { status = 201, body = rest_note(502, "Now", vim.NIL) } },
    { request = { method = "PUT", path = BASE .. "/draft_notes/32" }, response = { body = { id = 32, note = "Because!" } } },
    { request = { method = "DELETE", path = BASE .. "/draft_notes/32" }, response = { status = 204 } },
  })
  vim.api.nvim_win_set_cursor(win, { 6, 0 })
  keys("gc")
  local cw = composer_set("@user-2 Because")
  eq(chunks_text(vim.api.nvim_win_get_config(cw).footer), " [<C-s>] Add to review • [<C-r>] Add & resolve • [<C-p>] Post now • [<Esc>] Cancel ● unsaved ")
  set_drafts({ { id = 32, note = "@user-2 Because", discussion_id = "d1", resolve_discussion = true } })
  keys("<C-r>")
  H.wait_for(function()
    return row_of(win, "@user-2 Because") ~= nil
  end)
  eq(request(fake, "POST", BASE .. "/draft_notes").json, { note = "@user-2 Because", in_reply_to_discussion_id = "d1", resolve_discussion = true })
  eq(lines(g.members.content.buf)[row_of(win, "@user-2 Because") - 1]:find("└─ ╭ AE Ann Example  you ─", 1, true) ~= nil, true)
  eq(vim.endswith(lines(g.members.content.buf)[row_of(win, "@user-2 Because") - 1], "─ ◷ pending ─╮"), true)
  -- edit the pending reply
  vim.api.nvim_win_set_cursor(win, { row_of(win, "@user-2 Because"), 0 })
  keys("gE")
  cw = composer_set("Because!")
  eq(vim.api.nvim_win_get_config(cw).title[1][1], " ✎ Edit pending comment ")
  set_drafts({ { id = 32, note = "Because!", discussion_id = "d1", resolve_discussion = true } })
  keys("<C-s>")
  H.wait_for(function()
    return row_of(win, "Because!") ~= nil
  end)
  eq(request(fake, "PUT", BASE .. "/draft_notes/32").json, { note = "Because!" })
  -- someone else's published comment cannot be changed
  vim.api.nvim_win_set_cursor(win, { 6, 0 })
  keys("gE")
  eq(last_note(), "gg.ui: Only your own comments can be changed")
  -- delete the pending reply
  vim.api.nvim_win_set_cursor(win, { row_of(win, "Because!"), 0 })
  vim.ui.input = function(_, cb)
    cb("y")
  end
  set_drafts({})
  keys("gD")
  H.wait_for(function()
    return last_note() == "gg.ui: Comment deleted" and row_of(win, "Because!") == nil
  end)
  -- post now
  vim.api.nvim_win_set_cursor(win, { 6, 0 })
  keys("gc")
  composer_set("Now")
  keys("<C-p>")
  H.wait_for(function()
    return last_note() == "gg.ui: Reply added"
  end)
  eq(request(fake, "POST", BASE .. "/discussions/d1/notes").json, { body = "Now" })
end

T["view: gs submits the review with a summary, approving after it"] = function()
  local g, fake, win = open({
    { ["repeat"] = true, request = { method = "GET", path = BASE .. "/versions" }, response = { body = { { id = 1, head_commit_sha = HEAD, base_commit_sha = "b", start_commit_sha = "b" } } } },
    { request = { method = "POST", path = BASE .. "/draft_notes/bulk_publish" }, response = { status = 204 } },
    { request = { method = "POST", path = BASE .. "/approve" }, response = { status = 201, body = { approvals_required = 1, approvals_left = 0 } } },
  })
  local asked
  confirm.select = function(items, opts, cb)
    asked = { opts.prompt, vim.tbl_map(function(a)
      return a.key
    end, items) }
    cb(items[2])
  end
  keys("gs")
  eq(asked, { "Submit review · no pending comments", { "comment", "approve", "changes" } })
  local cw = composer_set("")
  eq(vim.api.nvim_win_get_config(cw).title[1][1], " Review summary · optional ")
  eq(vim.startswith(chunks_text(vim.api.nvim_win_get_config(cw).footer), " [<C-s>] Submit & approve • [<Esc>] Cancel "), true)
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(cw), 0, -1, false, { "Looks good" })
  keys("<C-s>")
  H.wait_for(function()
    return last_note() == "gg.ui: Review submitted and approved"
  end)
  eq(request(fake, "POST", BASE .. "/draft_notes/bulk_publish").json, { note = "Looks good" })
  eq(request(fake, "POST", BASE .. "/approve").json, { sha = HEAD })
  eq(vim.api.nvim_get_current_win(), win)
  eq(g.members.content ~= nil, true)
end

T["view: gs refuses when the merge request has new commits"] = function()
  local _, fake = open({
    { ["repeat"] = true, request = { method = "GET", path = BASE .. "/versions" }, response = { body = { { id = 2, head_commit_sha = "newer", base_commit_sha = "b", start_commit_sha = "b" } } } },
  })
  confirm.select = function(items, _, cb)
    cb(items[1])
  end
  keys("gs")
  composer_set("")
  keys("<C-s>")
  H.wait_for(function()
    return last_note() == "gg.ui: Review update failed: the merge request has new commits: reload and look at them first"
  end)
  eq(request(fake, "POST", BASE .. "/draft_notes/bulk_publish"), nil)
  keys("<Esc>")
end

T["merge request detail: gd opens the review, <CR> on a changed file opens it there"] = function()
  local fake = H.fake()
  fake:add(X.open_mr_responses())
  local r = responses()
  fake:add({ r[3], r[4] })
  fake:add({ ["repeat"] = true, request = { method = "GET", path = BASE .. "/draft_notes" }, response = { body = {} } })
  s = stack.new()
  detail.merge_request({ stack = s, cfg = config.get(), host = X.HOST, project = X.PROJECT, today = X.TODAY }, { iid = X.MR_IID })
  local mr_group = s:top().group
  H.wait_for(function()
    return #lines(mr_group.members.content.buf) > 4
  end)
  keys("gd")
  eq(s:depth(), 2)
  local g = s:top().group
  H.wait_for(function()
    return lines(g.members.content.buf)[3] == "   3   3   a"
  end)
  keys("q")
  eq(s:depth(), 1)
  eq(gg.diff.parse(DIFF)[2].new_start, 21)
end

return T
