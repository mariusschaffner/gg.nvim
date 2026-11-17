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
--- Side by side (`render_split`) there are two docs of the same length, one
--- per box: the old file and the new one (`model.pairs`), line N of one
--- beside line N of the other. A side with nothing beside a line of the
--- other gets an empty filler row; a thread goes on the side of its line
--- (the new one unless it is only on an old line), the other side gets as
--- many filler rows. Rows have the same metadata as unified ones.
local activity = require("gg.ui.detail.activity.render")
local doc = require("gg.ui.lib.doc")
local intraline = require("gg.ui.detail.review.intraline")
local line = require("gg.ui.lib.line")
local model = require("gg.ui.detail.review.model")

local M = {}

M.GAP = "⋯"
M.MIN_DIGITS = 3

local SIGN = { add = "+", delete = "-", context = " " }
local SIGN_HL = { add = "GitlabDiffAdd", delete = "GitlabDiffDelete" }
local LINE_HL = { add = "GitlabDiffAddLine", delete = "GitlabDiffDeleteLine" }
local TEXT_HL = { add = "GitlabDiffAddText", delete = "GitlabDiffDeleteText" }

---@class gg.ui.ReviewRenderInput
---@field width integer
---@field width_right? integer the right box's width (`render_split`)
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

local function rjust(n, w)
  local s = n and tostring(n) or ""
  return string.rep(" ", w - #s) .. s
end

local function hint(l, key, desc, hl)
  if key then
    l:add(" · ", hl):add("[" .. key .. "]", "GitlabHintKey"):add(" " .. desc, hl)
  end
end

-- what every diff needs before its rows; `d` nil: no rows (a state, or a
-- file without a diff), the doc says why
local function prelude(input, width)
  local d = doc.new()
  if input.status == "loading" then
    d:text(" Loading the changes…", "GitlabDetailMuted")
    return d, nil
  elseif input.status == "error" then
    d:text(" " .. (input.error or "Failed to load the changes"), "GitlabDetailError")
    return d, nil
  end
  local file = input.file
  if not file then
    d:text(" No changes.", "GitlabDetailMuted")
    return d, nil
  end
  local keys = input.keys or {}
  if input.truncated then
    d:text(" Not every file of this merge request was loaded (the limit was reached).", "GitlabDetailMuted")
  end
  local placed = input.placed or { top = {}, at = {} }
  local function thread_input(w)
    return {
      width = math.max(30, w),
      status = "ready",
      state = input.state,
      me = input.me,
      utc_offset = input.utc_offset,
      user_colors = input.user_colors,
      keys = { fold = keys.fold },
    }
  end
  if file.unavailable then
    if #placed.top > 0 then
      d:blank()
      for _, t in ipairs(placed.top) do
        activity.thread(d, t, thread_input(width))
      end
    end
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
    return d, nil
  end
  local rows = input.rows or {}
  return d,
    {
      file = file,
      keys = keys,
      placed = placed,
      rows = rows,
      thread_input = thread_input,
      -- the gutter's digits, the characters that changed inside a replaced line
      w = math.max(M.MIN_DIGITS, #tostring(model.max_line(rows))),
      changed = intraline.rows(rows),
    }
end

local function gap_row(d, input, r, i, lead)
  local l = line.new():add(string.rep(" ", lead)):add(M.GAP .. " ", "GitlabDiffGap")
  if r.count then
    l:add(("%d unchanged line%s"):format(r.count, r.count == 1 and "" or "s"), "GitlabDiffGap")
  else
    l:add("unchanged lines below", "GitlabDiffGap")
  end
  if input.fetching then
    l:add(" · loading…", "GitlabDiffGap")
  else
    hint(l, (input.keys or {}).fold, "expand", "GitlabDiffGap")
  end
  d:line(l, { kind = "fold", gap = r.gap, index = i })
end

local function hunk_row(d, r, i, lead)
  d:line(line.new():add(string.rep(" ", lead)):add((r.header:gsub("\r", "")), "GitlabDiffHunk"), { kind = "hunk", hunk = r.hunk, index = i })
end

-- one line of code; the gutter shows the old and the new line number, or
-- one of them (`side`)
local function code_row(d, r, i, side, w, changed)
  local l = line.new():add(" ")
  if side ~= "new" then
    l:add(rjust(r.old_line, w), "GitlabDiffLineNr"):add(" ")
  end
  if side ~= "old" then
    l:add(rjust(r.new_line, w), "GitlabDiffLineNr"):add(" ")
  end
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

--- Render the diff of `input.file`.
---@param input gg.ui.ReviewRenderInput
---@return gg.ui.Doc
function M.render(input)
  local d, c = prelude(input, input.width)
  if not c then
    return d
  end
  local ti = c.thread_input(input.width)
  local function threads(list)
    for _, t in ipairs(list or {}) do
      activity.thread(d, t, ti)
    end
  end
  if #c.placed.top > 0 then
    d:blank()
    threads(c.placed.top)
  end
  local lead = 2 * c.w + 3
  for i, r in ipairs(c.rows) do
    if r.kind == "gap" then
      gap_row(d, input, r, i, lead)
    elseif r.kind == "hunk" then
      hunk_row(d, r, i, lead)
    else
      code_row(d, r, i, nil, c.w, c.changed)
    end
    threads(c.placed.at[i])
  end
  return d
end

-- the side a thread goes on side by side
local function side_of(t)
  local a = t.anchor or {}
  return (a.old_line and not a.new_line) and "left" or "right"
end

--- Render the diff of `input.file` side by side: the old file (`width`
--- wide) and the new one (`width_right`), as two docs of the same length.
---@param input gg.ui.ReviewRenderInput
---@return gg.ui.Doc left
---@return gg.ui.Doc right
function M.render_split(input)
  local width_right = input.width_right or input.width
  local left, c = prelude(input, input.width)
  local right = doc.new()
  local filler = { kind = "filler" }
  -- the shorter side catches up with filler rows
  local function even()
    while #left.lines < #right.lines do
      left:blank(filler)
    end
    while #right.lines < #left.lines do
      right:blank(filler)
    end
  end
  if not c then
    even()
    return left, right
  end
  even()
  local inputs = { left = c.thread_input(input.width), right = c.thread_input(width_right) }
  local docs = { left = left, right = right }
  local function threads(list)
    for _, t in ipairs(list or {}) do
      local s = side_of(t)
      activity.thread(docs[s], t, inputs[s])
    end
    even()
  end
  if #c.placed.top > 0 then
    -- file comments and threads on lines not shown: on the new side
    right:blank()
    for _, t in ipairs(c.placed.top) do
      activity.thread(right, t, inputs.right)
    end
    even()
  end
  local lead = c.w + 4
  for _, p in ipairs(model.pairs(c.rows)) do
    if p.kind == "gap" then
      local r = c.rows[p.index]
      gap_row(left, input, r, p.index, lead)
      gap_row(right, input, r, p.index, lead)
      threads(c.placed.at[p.index])
    elseif p.kind == "hunk" then
      local r = c.rows[p.index]
      hunk_row(left, r, p.index, lead)
      hunk_row(right, r, p.index, lead)
    else
      if p.left then
        local r = c.rows[p.left]
        code_row(left, r, p.left, "old", c.w, c.changed)
      end
      if p.right then
        local r = c.rows[p.right]
        code_row(right, r, p.right, "new", c.w, c.changed)
      end
      even()
      local list = vim.list_extend({}, c.placed.at[p.left] or {})
      if p.right ~= p.left then
        vim.list_extend(list, c.placed.at[p.right] or {})
      end
      threads(list)
    end
  end
  return left, right
end

return M
