-- gg.ui.lib: display-width text, line builder, dates, hints.
local date = require("gg.ui.lib.date")
local hint = require("gg.ui.lib.hint")
local line = require("gg.ui.lib.line")
local text = require("gg.ui.lib.text")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["text.truncate: by display width, ellipsis when cut"] = function()
  eq(text.truncate("Rotate Terraform", 20), "Rotate Terraform")
  eq(text.truncate("Rotate Terraform", 8), "Rotate …")
  eq(text.width(text.truncate("Rotate Terraform", 8)), 8)
  eq(text.truncate("abc", 0), "")
  eq(text.truncate("abc", 1), "…")
  -- multi-byte glyphs are one cell each
  eq(text.truncate("▰▰▰▱▱▱", 4), "▰▰▰…")
  eq(text.truncate("● Open", 6), "● Open")
  -- wide characters never get split
  eq(text.truncate("日本語abc", 4), "日…")
  eq(text.width(text.truncate("日本語abc", 4)), 3)
end

T["text.pad: exact width, multi-byte safe"] = function()
  eq(text.pad("#214", 6), "#214  ")
  eq(text.pad("✓ Closed", 10), "✓ Closed  ")
  eq(text.width(text.pad("日本語abc", 4)), 4)
  eq(text.pad("long title here", 5), "long…")
end

T["text.clean: control characters become spaces"] = function()
  eq(text.clean("a\nb\tc"), "a b c")
  eq(text.clean(nil), "")
end

T["line: byte-range marks for multi-byte segments"] = function()
  local l = line.new():add("▎", "Edge"):add(" "):add("%2026.11", "Name"):pad_to(12):add("x", "X")
  local s, marks = l:result()
  eq(s, "▎ %2026.11  x")
  eq(marks, {
    { col = 0, end_col = 3, hl = "Edge" },
    { col = 4, end_col = 12, hl = "Name" },
    { col = 14, end_col = 15, hl = "X" },
  })
  eq(s:sub(marks[2].col + 1, marks[2].end_col), "%2026.11")
end

T["line: cell pads, highlights only the text, trailing spaces trimmed"] = function()
  local l = line.new():cell("#7", 6, "Iid"):cell("title", 4)
  local s, marks = l:result()
  eq(s, "#7    tit…")
  eq(marks, { { col = 0, end_col = 2, hl = "Iid" } })
  local s2 = line.new():add("a"):pad_to(10):result()
  eq(s2, "a")
end

T["date.due: tones and texts"] = function()
  local today = { year = 2026, month = 11, day = 8 }
  eq({ date.due("2026-11-20", today) }, { "due Nov 20 · in 12d", "normal" })
  eq({ date.due("2026-11-16", today) }, { "due Nov 16 · in 8d", "normal" })
  eq({ date.due("2026-11-15", today) }, { "due Nov 15 · in 7d", "soon" })
  eq({ date.due("2026-11-12", today) }, { "due Nov 12 · in 4d", "soon" })
  eq({ date.due("2026-11-08", today) }, { "due Nov 08 · today", "soon" })
  eq({ date.due("2026-11-06", today) }, { "due Nov 06 · 2d late", "overdue" })
  eq({ date.due("2026-11-06", today, true) }, { "due Nov 06", "normal" })
  eq({ date.due(nil, today) }, { "no due date", "none" })
  -- another year shows the year
  eq({ date.due("2027-01-05", today) }, { "due Jan 05 2027 · in 58d", "normal" })
  eq(date.short({ year = 2025, month = 12, day = 31 }, today), "Dec 31 2025")
end

T["date.parse: dates and timestamps"] = function()
  eq(date.parse("2026-11-20"), { year = 2026, month = 11, day = 20 })
  eq(date.parse("2026-11-20T10:00:00Z"), { year = 2026, month = 11, day = 20 })
  eq(date.parse("nope"), nil)
  eq(date.parse(nil), nil)
  eq(date.days_between({ year = 2026, month = 3, day = 28 }, { year = 2026, month = 4, day = 2 }), 5)
end

T["hint: always [key] description"] = function()
  eq(hint.text("R", "Retry"), "[R] Retry")
  eq(hint.chunks({ { key = "I", desc = "Milestone" }, { key = "i", desc = "Issue" } }), {
    { " ", "GitlabHintText" },
    { "[I]", "GitlabHintKey" },
    { " Milestone", "GitlabHintText" },
    { " • ", "GitlabHintText" },
    { "[i]", "GitlabHintKey" },
    { " Issue", "GitlabHintText" },
    { " ", "GitlabHintText" },
  })
end

return T
