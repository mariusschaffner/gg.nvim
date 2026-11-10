-- Pure building blocks of the detail views.
local avatar = require("gg.ui.lib.avatar")
local chip = require("gg.ui.lib.chip")
local date = require("gg.ui.lib.date")
local doc = require("gg.ui.lib.doc")
local header = require("gg.ui.detail.header")
local layout = require("gg.ui.components.layout")
local markdown = require("gg.ui.lib.markdown")
local progress = require("gg.ui.lib.progress")
local sidebar = require("gg.ui.detail.sidebar")
local text = require("gg.ui.lib.text")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function joined(segs)
  return table.concat(vim.tbl_map(function(s)
    return s[1]
  end, segs))
end

T["text.wrap: words, indentation, long words, multi-byte"] = function()
  eq(text.wrap("", 10), { "" })
  eq(text.wrap("one two three four", 9), { "one two", "three", "four" })
  eq(text.wrap("  indented line here", 12), { "  indented", "line here" })
  eq(text.wrap("abcdefghijkl", 5), { "abcde", "fghij", "kl" })
  eq(text.wrap("● ✓ — …", 3), { "● ✓", "— …" })
  for _, l in ipairs(text.wrap("Rotate Terraform state backend credentials now", 10)) do
    eq(text.width(l) <= 10, true)
  end
end

T["date: age, clock, hhmm, day labels, weekday, add_days"] = function()
  local now = date.parse_time("2026-11-10T12:00:00Z")
  eq(date.age("2026-11-10T11:59:58Z", now), "now")
  eq(date.age("2026-11-10T11:58:00Z", now), "2m")
  eq(date.age("2026-11-10T09:00:00Z", now), "3h")
  eq(date.age("2026-11-08T12:00:00Z", now), "2d")
  eq(date.age("2026-10-20T12:00:00Z", now), "3w")
  eq(date.age("2026-06-01T12:00:00Z", now), "5mo")
  eq(date.age("2024-01-01T12:00:00Z", now), "2y")
  eq(date.age(nil, now), "")
  eq({ date.clock(12), date.clock(62), date.clock(3723), date.clock(nil) }, { "12s", "1:02", "1:02:03", "" })
  eq(date.hhmm("2026-11-10T08:05:00Z", 3600), "09:05")
  eq(date.local_day("2026-11-10T23:30:00Z", 3600), { year = 2026, month = 11, day = 11 })
  local today = { year = 2026, month = 11, day = 10 }
  eq(date.day_label(today, today), "TODAY · 10.11.2026")
  eq(date.day_label({ year = 2026, month = 11, day = 9 }, today), "YESTERDAY · 09.11.2026")
  eq(date.day_label({ year = 2026, month = 10, day = 1 }, today), "01.10.2026")
  eq(date.weekday(today), 2) -- a Tuesday
  eq(date.add_days(today, 25), { year = 2026, month = 12, day = 5 })
  eq(date.diff_days(today, { year = 2027, month = 1, day = 1 }), 52)
  eq(date.dotted_short(today), "10.11.")
end

T["doc: lines, marks follow their rows, append shifts"] = function()
  local d = doc.new()
  d:text("first", "A", { kind = "x" })
  d:segments({ { "a", "B" }, { "b" }, { "c", "C" } })
  eq(d.lines, { "first", "abc" })
  eq(d.marks, { { row = 0, col = 0, end_col = 5, hl = "A" }, { row = 1, col = 0, end_col = 1, hl = "B" }, { row = 1, col = 2, end_col = 3, hl = "C" } })
  eq(d.rows[1], { kind = "x" })
  local outer = doc.new()
  outer:blank()
  outer:line_hl(1, "Bg")
  outer:append(d)
  eq(outer.lines, { "", "first", "abc" })
  eq(outer.rows[2], { kind = "x" })
  eq(outer.marks[3].row, 2)
  eq(outer.line_hls, { { row = 0, hl = "Bg" } })
end

T["header: crumb, border title width and truncation"] = function()
  eq(header.crumb("issues"), "issues › ") -- no group / project
  local t = header.border_title(80, header.crumb("issues"), "#17", { { "updated 2h ago" } })
  eq(text.width(joined(t)), 80)
  eq(t[1][1], " issues › ")
  eq(t[3][2], "GitlabDetailBorder") -- the fill is gray like the border
  eq(t[2], { "#17 ", "GitlabDetailRef" })
  eq(vim.endswith(joined(t), " updated 2h ago "), true)
  -- narrow: the crumb is cut from the start, then the meta goes
  local long = "a-very-long-crumb-that-does-not-fit-anywhere › merge requests › "
  t = header.border_title(60, long, "!36", { { "opened by someone · updated 3h ago" } })
  eq(text.width(joined(t)) <= 60, true)
  eq(joined(t):find("!36", 1, true) ~= nil, true)
end

T["header: title line, chips, strip, extra"] = function()
  local extra = doc.new()
  extra:text("EXTRA")
  local d = header.build({
    width = 60,
    pill = chip.pill("●", "Open", "GitlabPillOpened"),
    title = "Rotate credentials",
    ref = "#17",
    title_right = { { "3:05 elapsed" } },
    chips = { { " docs ", "X" } },
    strip = "Open · unassigned",
    extra = extra,
  })
  -- an empty line above the title and one at the end
  eq(d.lines[1], "")
  eq(vim.startswith(d.lines[2], "  ● Open  Rotate credentials #17"), true)
  eq(vim.endswith(d.lines[2], "3:05 elapsed"), true)
  eq(text.width(d.lines[2]), 59)
  eq(d.lines[3], "")
  eq(d.lines[4], "  docs ") -- a chip keeps its padding
  eq(d.lines[5], " Open · unassigned")
  eq({ d.lines[6], d.lines[7], d.lines[8] }, { "", "EXTRA", "" })
  eq(#d.lines, 8)
  -- a long title is cut, the right text dropped when there is no room
  d = header.build({ width = 30, pill = chip.pill("●", "Open", "X"), title = string.rep("x", 40), ref = "#1", title_right = { { "right side text" } } })
  eq(text.width(d.lines[2]) <= 29, true)
  eq(d.lines[2]:find("right", 1, true), nil)
end

T["header: tabs title"] = function()
  local t = header.tabs_title({ { key = "a", label = "Description" }, { key = "b", label = "Activity", count = 12 } }, "b")
  -- right after the border corner, like " Table " in the picker
  eq(joined(t), " Description   Activity 12  ")
  eq(t[1][2], "GitlabDetailTab")
  eq(t[3][2], "GitlabDetailTabActive") -- the picker's title colour, no background
end

T["sidebar: fields, empty values, dividers, spread"] = function()
  local d = sidebar.build({
    { label = "Assignee", lines = { { { "(MS)", "U" }, { " Marius" } } } },
    { label = "Labels", lines = {}, empty = "no labels" },
    { divider = true },
    { label = "Dates", label_right = "start | due", lines = { sidebar.spread({ { "2026-11-01" } }, { { "2026-11-14" } }, 30) } },
  }, 32)
  eq(d.lines, {
    " ASSIGNEE",
    " (MS) Marius",
    "",
    " LABELS",
    " no labels",
    "",
    " " .. string.rep("─", 30),
    "",
    " DATES              start | due",
    " 2026-11-01          2026-11-14",
  })
  eq(sidebar.inner(32), 30)
end

T["avatar: initials and segments"] = function()
  eq(avatar.initials("Marius Schaffner"), "MS")
  eq(avatar.initials("marius"), "MA")
  eq(avatar.initials("Anna Maria von Berg"), "AB")
  eq(avatar.initials(""), "??")
  local segs = avatar.segments({ username = "msch", name = "Marius Schaffner" }, { me = "msch" })
  eq(joined(segs), "(MS) Marius Schaffner you")
  eq(segs[1][2]:match("^GitlabUser%d$") ~= nil, true)
  eq(joined(avatar.segments(nil)), "unknown")
end

T["progress: dots and buckets"] = function()
  eq(joined(progress.dots(4, 6)), "● ● ● ● ○ ○")
  eq(joined(progress.dots(0, 0)), "○")
  eq(joined(progress.dots(5, 5, 3)), "● ● ●")
  local b = progress.buckets(2, 2, 6)
  eq(joined(b), "● ● ● ● ○ ○ ○ ○ ○ ○")
  eq({ b[1][2], b[5][2], b[9][2] }, { "GitlabProgressDone", "GitlabProgressDoing", "GitlabProgressTodo" })
  eq(#vim.tbl_filter(function(s)
    return s[1] ~= " "
  end, progress.buckets(30, 10, 60)), 20)
end

T["chip: labels wrap, pills"] = function()
  local labels = { { title = "WF:Doing", color = "#ff0000" }, { title = "docs" }, { title = "backend" } }
  local lines = chip.wrap(labels, 17, function(c)
    return c and "C" or "F"
  end)
  eq(vim.tbl_map(joined, lines), { " WF:Doing   docs ", " backend " })
  eq(lines[1][1][2], "C")
  eq(lines[1][3][2], "F")
  eq(chip.pill("●", "Open", "P"), { " ● Open ", "P" })
end

T["layout.detail: header, content and sidebar rects"] = function()
  local r = layout.detail({ header_h = 4, sidebar = true, area = { columns = 160, lines = 40 } })
  eq(r.header, { row = 0, col = 0, width = 158, height = 4 })
  -- one empty row between the header and the boxes below
  eq(r.content, { row = 7, col = 0, width = 123, height = 31 })
  eq(r.sidebar, { row = 7, col = 126, width = 32, height = 31 })
  -- narrow: no sidebar
  r = layout.detail({ header_h = 4, sidebar = true, area = { columns = 90, lines = 40 } })
  eq(r.sidebar, nil)
  eq(r.content.width, 88)
  -- the header is capped
  r = layout.detail({ header_h = 100, area = { columns = 120, lines = 40 } })
  eq(r.header.height, layout.header_max({ columns = 120, lines = 40 }))
end

T["markdown: headings with task counts, tasks, bullets, fences, hashtags"] = function()
  local src = table.concat({
    "# Plan",
    "",
    "- [x] first **step**",
    "- [ ] second",
    "",
    "* a bullet with [a link](https://x)",
    "  - nested",
    "Talk in #infra about it",
    "```",
    "- [ ] not a task",
    "```",
    "after the **fence**",
    "",
    "",
  }, string.char(10))
  eq({ markdown.tasks(src) }, { 1, 2 })
  local d = markdown.render(src, { width = 40 })
  eq(d.lines, {
    " Plan                        1 of 2 done",
    "",
    " ✓ first step",
    " ○ second",
    "",
    " • a bullet with a link",
    "   – nested",
    " Talk in #infra about it",
    " ```",
    " - [ ] not a task",
    " ```",
    " after the fence",
  })
  eq(d.rows[3], { src = 3, kind = "task", done = true })
  eq(d.rows[8].src, 8)
  local tag
  for _, m in ipairs(d.marks) do
    if m.row == 7 and m.hl == "GitlabDetailHashtag" then
      tag = d.lines[8]:sub(m.col + 1, m.end_col)
    end
  end
  eq(tag, "#infra")
  -- wrapping keeps continuation lines under the text
  d = markdown.render("- [ ] a task with a rather long text that wraps", { width = 24 })
  eq(d.lines, { " ○ a task with a rather", "   long text that wraps" })
  eq(markdown.render("", { width = 20 }).lines, { " No description" })
  eq(markdown.render("x", { width = 20, replace = function(i, s)
    local r = require("gg.ui.lib.doc").new()
    r:text("card " .. i .. s)
    return r
  end }).lines, { "card 1x" })
end

return T
