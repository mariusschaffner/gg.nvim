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
  for i, r in ipairs(rows) do
    if r.kind == "gap" then
      local l = line.new():add(" " .. string.rep(" ", 2 * w + 1) .. " "):add(M.GAP .. " ", "GitlabDiffGap")
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
    elseif r.kind == "hunk" then
      d:line(line.new():add(" " .. string.rep(" ", 2 * w + 1) .. " "):add((r.header:gsub("\r", "")), "GitlabDiffHunk"), { kind = "hunk", hunk = r.hunk, index = i })
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

return M
