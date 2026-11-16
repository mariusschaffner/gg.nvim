--- Draw one file's diff with its threads. Pure.
---
---    ⋯ 39 unchanged lines · [za] expand
---    @@ -40,7 +40,9 @@ local function request(opts)
---    40  40    local args = build(opts)
---    41      - local res = run(args)
---        41  + local res, err = retry(run, args)
---    ╭ MS Marius ─────────────────────── ◷ pending ─╮
---    │ should this back off on 429 only?             │
---    ╰───────────────────────────────────────────────╯
---    42  43    return res
---
--- Every line of the diff is a buffer line (removed ones too), so each can
--- take a comment. Added and removed lines have a whole-line tint; where a
--- removed line was replaced by an added one, the characters that differ
--- are marked on both. Threads
--- are drawn with the Activity tab's comment boxes under the line they are on.
---
--- Side by side (`split`), the old file is on the left and the new one on
--- the right (`model.pairs`), a line of each per buffer line:
---
---     40    local args = build(opts)   │  40    local args = build(opts)
---     41  - local res = run(args)      │  41  + local res, err = retry(run, args)
---
--- Its row metadata has both sides (`left`, `right`: what a unified row
--- has, plus the text's byte length `len`) and `sep`, the byte column of
--- the separator: the view takes the side the cursor is on.
local activity = require("gg.ui.detail.activity.render")
local doc = require("gg.ui.lib.doc")
local intraline = require("gg.ui.detail.review.intraline")
local line = require("gg.ui.lib.line")
local model = require("gg.ui.detail.review.model")
local text = require("gg.ui.lib.text")

local M = {}

M.GAP = "⋯"
M.MIN_DIGITS = 3
M.SEP = "│" -- between the sides of a side-by-side diff
M.TABSTOP = 4 -- tabs become spaces side by side (the columns must line up)

local SIGN = { add = "+", delete = "-", context = " " }
local SIGN_HL = { add = "GitlabDiffAdd", delete = "GitlabDiffDelete" }
local LINE_HL = { add = "GitlabDiffAddLine", delete = "GitlabDiffDeleteLine" }
local TEXT_HL = { add = "GitlabDiffAddText", delete = "GitlabDiffDeleteText" }

---@class gg.ui.ReviewRenderInput
---@field width integer
---@field status "loading"|"ready"|"error"
---@field error? string
---@field file? gg.ui.ReviewFile
---@field rows? gg.ui.ReviewRow[]
---@field placed? gg.ui.ReviewPlaced
---@field state? gg.ui.ActivityState folded threads, expanded long comments
---@field me? string signed-in username
---@field utc_offset? integer
---@field user_colors? table<string, string>
---@field keys? { fold?: string } first key of `toggle_fold`
---@field fetching? boolean the file's content is being fetched (an expand is waiting)
---@field truncated? boolean the merge request has more files than were loaded
---@field split? boolean side by side

local function rjust(n, w)
  local s = n and tostring(n) or ""
  return string.rep(" ", w - #s) .. s
end

local function hint(l, key, desc, hl)
  if key then
    l:add(" · ", hl):add("[" .. key .. "]", "GitlabHintKey"):add(" " .. desc, hl)
  end
end

--- Render the diff of `input.file`.
---@param input gg.ui.ReviewRenderInput
---@return gg.ui.Doc
function M.render(input)
  local d = doc.new()
  if input.status == "loading" then
    d:text(" Loading the changes…", "GitlabDetailMuted")
    return d
  elseif input.status == "error" then
    d:text(" " .. (input.error or "Failed to load the changes"), "GitlabDetailError")
    return d
  end
  local file = input.file
  if not file then
    d:text(" No changes.", "GitlabDetailMuted")
    return d
  end
  local keys = input.keys or {}
  local thread_input = {
    width = math.max(30, input.width),
    status = "ready",
    state = input.state,
    me = input.me,
    utc_offset = input.utc_offset,
    user_colors = input.user_colors,
    keys = { fold = keys.fold },
  }
  local placed = input.placed or { top = {}, at = {} }
  local function threads(list)
    for _, t in ipairs(list or {}) do
      activity.thread(d, t, thread_input)
    end
  end
  if input.truncated then
    d:text(" Not every file of this merge request was loaded (the limit was reached).", "GitlabDetailMuted")
  end
  if #placed.top > 0 then
    d:blank()
    threads(placed.top)
  end
  if file.unavailable then
    local l = line.new():add(" ")
    if file.unavailable == "no text changes" then
      l:add(file.status == "R" and "Renamed without changes." or "No text changes (binary or mode change).", "GitlabDetailMuted")
      d:line(l, { kind = "unavailable" })
    else
      l:add(("The diff is not shown: %s."):format(file.unavailable), "GitlabDetailMuted")
      if input.fetching then
        l:add(" · loading…", "GitlabDetailMuted")
      else
        hint(l, keys.fold, "load", "GitlabDetailMuted")
      end
      d:line(l, { kind = "unavailable", loadable = true })
    end
    return d
  end
  local rows = input.rows or {}
  local w = math.max(M.MIN_DIGITS, #tostring(model.max_line(rows)))
  -- the characters that changed inside a replaced line
  local changed = intraline.rows(rows)
  local function gap_row(r, i, lead)
    local l = line.new():add(string.rep(" ", lead)):add(M.GAP .. " ", "GitlabDiffGap")
    if r.count then
      l:add(("%d unchanged line%s"):format(r.count, r.count == 1 and "" or "s"), "GitlabDiffGap")
    else
      l:add("unchanged lines below", "GitlabDiffGap")
    end
    if input.fetching then
      l:add(" · loading…", "GitlabDiffGap")
    else
      hint(l, keys.fold, "expand", "GitlabDiffGap")
    end
    d:line(l, { kind = "fold", gap = r.gap, index = i })
  end
  local function hunk_row(r, i, lead)
    d:line(line.new():add(string.rep(" ", lead)):add((r.header:gsub("\r", "")), "GitlabDiffHunk"), { kind = "hunk", hunk = r.hunk, index = i })
  end
  if input.split then
    M._split(d, input, rows, placed, changed, w, gap_row, hunk_row, threads)
    return d
  end
  for i, r in ipairs(rows) do
    if r.kind == "gap" then
      gap_row(r, i, 2 * w + 3)
    elseif r.kind == "hunk" then
      hunk_row(r, i, 2 * w + 3)
    else
      local l = line.new():add(" ")
      l:add(rjust(r.old_line, w), "GitlabDiffLineNr"):add(" "):add(rjust(r.new_line, w), "GitlabDiffLineNr"):add(" ")
      if r.type == "context" then
        l:add("  ")
      else
        l:add(SIGN[r.type], SIGN_HL[r.type]):add(" ")
      end
      local col = l.bytes
      l:add((r.text:gsub("\r", "")))
      local lnum = d:line(l, { kind = "line", type = r.type, old_line = r.old_line, new_line = r.new_line, index = i, col = col, gap = r.gap })
      if LINE_HL[r.type] then
        -- below the code's colours and the marked characters (a whole-line
        -- highlight group would paint over both)
        d:line_tint(lnum, LINE_HL[r.type])
      end
      for _, range in ipairs(changed[i] or {}) do
        table.insert(d.marks, { row = lnum - 1, col = col + range[1], end_col = col + range[2], hl = TEXT_HL[r.type], priority = 110 })
      end
    end
    threads(placed.at[i])
  end
  return d
end


-- `s` (a line of code) as shown in `width` cells side by side: tabs as
-- spaces, cut to fit. Returns the text, a function from a byte offset in
-- `s` to one in the text, and whether it was cut.
local function shown(s, width)
  s = s:gsub("\r", "")
  local parts, starts, ends = {}, {}, {}
  local w, b = 0, 0
  for at, ch in s:gmatch("()([%z\1-\127\194-\244][\128-\191]*)") do
    starts[at - 1] = b
    if ch == "\t" then
      ch = string.rep(" ", M.TABSTOP - w % M.TABSTOP)
    end
    table.insert(parts, ch)
    w, b = w + text.width(ch), b + #ch
    table.insert(ends, { b, w })
  end
  starts[#s] = b
  local out, cut = table.concat(parts), false
  if w > width then
    cut = true
    local keep = 0
    for _, e in ipairs(ends) do
      if e[2] > width - text.width(text.ELLIPSIS) then
        break
      end
      keep = e[1]
    end
    out = out:sub(1, keep)
  end
  return out, function(off)
    return math.min(starts[off] or #out, #out)
  end, cut
end

-- the side-by-side rows (see the top of this file)
---@private
function M._split(d, input, rows, placed, changed, w, gap_row, hunk_row, threads)
  local half = math.floor((input.width - text.width(M.SEP)) / 2)
  local gutter = w + 4 -- " 41 - "
  local widths = { math.max(1, half - gutter), math.max(1, input.width - half - 1 - gutter) }
  local lead = gutter -- gaps and hunk headers start where the old text does
  for _, p in ipairs(model.pairs(rows)) do
    if p.kind == "gap" then
      gap_row(rows[p.index], p.index, lead)
      threads(placed.at[p.index])
    elseif p.kind == "hunk" then
      hunk_row(rows[p.index], p.index, lead)
    else
      local l = line.new()
      local sides, tints, sep = {}, {}, nil
      for s, i in ipairs({ p.left or false, p.right or false }) do
        if s == 2 then
          l:pad_to(half)
          sep = l.bytes
          l:add(M.SEP, "GitlabDiffSeparator")
        end
        local start = l.bytes
        local r = i and rows[i]
        if r then
          l:add(" "):add(rjust(s == 1 and r.old_line or r.new_line, w), "GitlabDiffLineNr"):add(" ")
          if r.type == "context" then
            l:add("  ")
          else
            l:add(SIGN[r.type], SIGN_HL[r.type]):add(" ")
          end
          local col = l.bytes
          local str, at, cut = shown(r.text, widths[s])
          l:add(str)
          if cut then
            l:add(text.ELLIPSIS, "GitlabDiffGap")
          end
          sides[s] = { type = r.type, old_line = r.old_line, new_line = r.new_line, index = i, col = col, len = #str, gap = r.gap }
          for _, range in ipairs(changed[i] or {}) do
            local from, to = at(range[1]), at(range[2])
            if to > from then
              table.insert(tints, { col = col + from, end_col = col + to, hl = TEXT_HL[r.type], priority = 110 })
            end
          end
          if LINE_HL[r.type] then
            -- the left side up to the separator, the right one to the edge
            table.insert(tints, { col = start, hl = LINE_HL[r.type], priority = 10, eol = s == 2 })
          end
        end
      end
      local both = p.left == p.right
      local info = {
        kind = "line",
        split = true,
        type = both and "context" or "change",
        gap = both and sides[1].gap or nil,
        left = sides[1],
        right = sides[2],
        sep = sep,
      }
      local lnum = d:line(l, info)
      for _, t in ipairs(tints) do
        local m = { row = lnum - 1, col = t.col, end_col = t.end_col, hl = t.hl, priority = t.priority }
        if t.eol then
          m.end_row, m.end_col, m.hl_eol = lnum, 0, true
        elseif not t.end_col then
          m.end_col = sep
        end
        table.insert(d.marks, m)
      end
      threads(placed.at[p.left])
      if p.right ~= p.left then
        threads(placed.at[p.right])
      end
    end
  end
end

return M
