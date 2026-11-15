-- The activity timeline: model (events, threads, runs, days) and render.
local model = require("gg.ui.detail.activity.model")
local render = require("gg.ui.detail.activity.render")
local text = require("gg.ui.lib.text")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local TODAY = { year = 2026, month = 11, day = 10 }
local ann = { username = "ann", name = "Ann Example" }
local bob = { username = "bob", name = "Bob Sample" }

local function sys(id, body, at, icon)
  return { id = "d" .. id, notes = { { id = id, body = body, system = true, created_at = at, author = ann, system_note_icon_name = icon } } }
end

local function thread(id, notes, extra)
  local d = { id = "t" .. id, notes = notes, resolvable = false, resolved = false }
  for k, v in pairs(extra or {}) do
    d[k] = v
  end
  return d
end

local function note(id, body, at, author, extra)
  local n = { id = id, body = body, system = false, created_at = at, author = author or ann }
  for k, v in pairs(extra or {}) do
    n[k] = v
  end
  return n
end

local function kinds(items)
  return vim.tbl_map(function(i)
    return i.kind
  end, items)
end

T["icons: GitLab icon names first, then the text"] = function()
  eq(model.icon("label", "whatever"), "◈")
  eq(model.icon(nil, "assigned to @bob"), "@")
  eq(model.icon(nil, "changed the description"), "✎")
  eq(model.icon("status_closed", ""), "✕")
  eq(model.icon(nil, "mentioned in merge request !12"), "↗")
  eq(model.icon(nil, "something new"), "•")
end

T["event text and markup"] = function()
  eq(model.event_text("marked the checklist item **Deploy** as completed"), "checked **Deploy**")
  eq(model.event_text("marked the checklist item x as incomplete\nsecond"), "unchecked x")
  eq(model.event_text("<!-- hidden -->added [docs](/labels/1) label"), "added docs label")
  eq(model.body_lines("one\n<b>two</b>\n\n\n"), { "one", "two" })
end

T["build: sorted oldest first, day dividers, events before comments"] = function()
  local items = model.build({
    thread(1, { note(10, "a comment", "2026-11-10T10:00:00Z") }),
    sys(2, "added ~docs label", "2026-11-10T10:00:00Z", "label"),
    sys(3, "assigned to @bob", "2026-11-09T08:00:00Z"),
  }, { today = TODAY, utc_offset = 0 })
  eq(kinds(items), { "day", "event", "day", "event", "thread" })
  eq(items[1].label, "YESTERDAY · 09.11.2026")
  eq(items[3].label, "TODAY · 10.11.2026")
  eq({ items[4].icon, items[4].actor, items[4].time }, { "◈", "Ann Example", "10:00" })
  eq(items[5].root.id, 10)
end

T["build: long runs collapse until expanded"] = function()
  local list = {}
  for i = 1, 7 do
    table.insert(list, sys(i, "changed title " .. i, ("2026-11-10T10:0%d:00Z"):format(i)))
  end
  local items = model.build(list, { today = TODAY, utc_offset = 0 })
  eq(kinds(items), { "day", "event", "event", "more", "event", "event" })
  eq(items[4].count, 3)
  local state = { expanded_runs = { [items[4].run] = true } }
  eq(#model.build(list, { today = TODAY, utc_offset = 0, state = state }), 8)
  -- a comment breaks a run: two short runs stay
  table.insert(list, thread(9, { note(90, "hi", "2026-11-10T10:04:30Z") }))
  eq(kinds(model.build(list, { today = TODAY, utc_offset = 0 })), { "day", "event", "event", "event", "event", "thread", "event", "event", "event" })
end

T["build: threads, replies, folds, diff context"] = function()
  local d = thread(1, {
    note(1, "root", "2026-11-10T10:00:00Z", ann, { position = { new_path = "a/b.lua", new_line = 12 } }),
    note(2, "reply", "2026-11-10T10:05:00Z", bob),
    { id = 3, body = "resolved", system = true, created_at = "2026-11-10T10:06:00Z" },
  }, { resolvable = true, resolved = false })
  local items = model.build({ d }, { today = TODAY, utc_offset = 0 })
  local t = items[2]
  eq({ t.kind, t.context, #t.replies, t.resolvable, t.folded }, { "thread", "a/b.lua:12", 1, true, false })
  items = model.build({ d }, { today = TODAY, utc_offset = 0, state = { folded = { t1 = true } } })
  eq(items[2].folded, true)
end

T["reactions: counted, most frequent first, emoji for known names"] = function()
  eq(model.reactions({ { name = "tada" }, { name = "thumbsup" }, { name = "thumbsup" }, { name = "custom" } }), {
    { "👍", 2 },
    { ":custom:", 1 },
    { "🎉", 1 },
  })
end

local function rendered(discussions, extra)
  local input = vim.tbl_extend("force", {
    width = 80,
    status = "ready",
    items = model.build(discussions, { today = TODAY, utc_offset = 0, state = extra and extra.state }),
    utc_offset = 0,
    keys = { expand = "<CR>", fold = "za" },
  }, extra or {})
  return render.render(input)
end

T["render: day rule, event row with right-aligned time"] = function()
  local d = rendered({ sys(1, "added **docs** label to !12", "2026-11-10T09:12:00Z", "label") })
  eq(d.lines[1], " TODAY · 10.11.2026 " .. string.rep("─", 80 - 20))
  eq(vim.startswith(d.lines[2], "   ◈  Ann Example added docs label to !12   "), true)
  eq(vim.endswith(d.lines[2], " 09:12"), true)
  eq(text.width(d.lines[2]), 80)
  eq(d.rows[2].kind, "event")
  local hls = {}
  for _, m in ipairs(d.marks) do
    if m.row == 1 then
      hls[d.lines[2]:sub(m.col + 1, m.end_col)] = m.hl
    end
  end
  eq(hls["docs"], "GitlabTimelineObject")
  eq(hls["!12"], "GitlabTimelineRef")
  eq(hls["Ann Example"], "GitlabTimelineActor")
end

T["render: comment blocks, badges, replies, truncation, folds"] = function()
  local long = {}
  for i = 1, 12 do
    table.insert(long, "line " .. i)
  end
  local d = rendered({
    thread(1, {
      note(1, table.concat(long, "\n"), "2026-11-10T10:00:00Z", ann, { reactions = { { name = "thumbsup" } } }),
      note(2, "first reply", "2026-11-10T10:05:00Z", bob),
      note(3, "second reply", "2026-11-10T10:06:00Z", ann),
    }, { resolvable = true, resolved = true }),
  }, { me = "ann" })
  -- a box: author and badges in the top border, the time on its right
  eq(d.lines[2], "  ╭ AE Ann Example  you  ✓ resolved thread " .. ("─"):rep(20) .. " 10:00 ─╮")
  eq(text.width(d.lines[2]), 72) -- the box is 90% of the width
  eq(d.lines[3], "  │ line 1" .. (" "):rep(61) .. "│")
  -- 8 body lines, then the cut marker
  eq(vim.startswith(d.lines[11], "  │ … [za] expand"), true)
  eq(d.rows[11].long, true)
  eq(vim.startswith(d.lines[12], "  │ 👍 1"), true)
  eq(text.width(d.lines[12]), 72)
  eq(d.lines[13], "  ╰" .. ("─"):rep(68) .. "╯")
  eq(vim.startswith(d.lines[14], "      ├─ ╭ BS Bob Sample ─"), true)
  eq(vim.endswith(d.lines[14], "─ 10:05 ─╮"), true)
  eq(vim.startswith(d.lines[15], "      │  │ first reply"), true)
  eq(vim.startswith(d.lines[16], "      │  ╰──"), true)
  eq(vim.startswith(d.lines[17], "      └─ ╭ AE Ann Example  you ─"), true)
  eq(vim.startswith(d.lines[18], "         │ second reply"), true)
  eq(vim.startswith(d.lines[19], "         ╰──"), true)
  eq(text.width(d.lines[19]), 72)
  local box = { col = 6 + #"│  ", width = 63 }
  eq(d.rows[15], { kind = "comment", thread = "t1", note = 2, long = false, box = box })
  eq(d.rows[14].box, box)
  eq(d.rows[16].box, box)
  -- border and name in the author's colour, each user their own
  local function hl_at(row, s)
    local col = d.lines[row]:find(s, 1, true) - 1
    for _, m in ipairs(d.marks) do
      if m.row == row - 1 and m.col == col then
        return m.hl
      end
    end
  end
  local user_hl = require("gg.ui.lib.user_hl")
  local n = user_hl.hash("ann") % user_hl.COUNT + 1
  eq(hl_at(2, "╭"), "GitlabCommentBorder" .. n)
  eq(hl_at(3, "│"), "GitlabCommentBorder" .. n)
  eq(hl_at(13, "╰"), "GitlabCommentBorder" .. n)
  eq(hl_at(2, "Ann Example"), "GitlabUser" .. n)
  eq(hl_at(14, "╭"), user_hl.border("bob"))
  eq(hl_at(14, "Bob Sample"), user_hl.group("bob"))
  eq(user_hl.border("bob") ~= hl_at(2, "╭"), true)
  -- the key hints go into the bottom border, after "╰─"
  local chunks, at = render.foot_hint(d.rows, 14, { { "[gc]", "GitlabHintKey" }, { " reply", "GitlabHintText" } })
  eq(at, { lnum = 16, col = box.col + #"╰─" })
  eq(chunks, { { " " }, { "[gc]", "GitlabHintKey" }, { " reply", "GitlabHintText" }, { " " } })
  eq(d.lines[16]:sub(at.col - #"╰─" + 1, at.col), "╰─")
  eq(select(2, render.foot_hint(d.rows, 16, {})), at) -- from any line of the box
  eq(render.foot_hint(d.rows, 1, {}), nil) -- not a box
  -- cut to the box
  local narrow = { col = 0, width = 10 }
  chunks = render.foot_hint({ { box = narrow } }, 1, { { "[gc] reply · [gE] edit", "X" } })
  eq(text.width(table.concat(vim.tbl_map(function(c)
    return c[1]
  end, chunks))), 6)
  -- expanded and folded
  d = rendered({
    thread(1, {
      note(1, table.concat(long, "\n"), "2026-11-10T10:00:00Z"),
      note(2, "first reply", "2026-11-10T10:05:00Z", bob),
    }),
  }, { state = { expanded_notes = { [1] = true }, folded = { t1 = true } } })
  eq(d.lines[16], "     ▸ 1 reply · [za] expand")
  eq(d.rows[16], { kind = "replies", thread = "t1" })
  -- a long header drops the time first, then is cut
  d = rendered({
    thread(1, { note(1, "x", "2026-11-10T10:00:00Z", { username = "ann", name = ("N"):rep(80) }) }),
  })
  eq(text.width(d.lines[2]), 72)
  eq(d.lines[2]:find("10:00", 1, true), nil)
  eq(vim.endswith(d.lines[2], "…╮"), true)
end

T["render: loading, error, empty"] = function()
  eq(render.render({ width = 50, status = "loading", keys = {} }).lines, { " Loading activity…" })
  eq(render.render({ width = 50, status = "error", error = "boom", keys = {} }).lines, { " boom" })
  eq(render.render({ width = 50, status = "ready", items = {}, keys = {} }).lines, { " No activity yet." })
end

return T
