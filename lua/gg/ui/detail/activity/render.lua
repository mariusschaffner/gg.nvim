--- Draw the activity timeline (`gg.ui.detail.activity.model`). Pure.
---
---  TODAY · 10.11.2026 ─────────────────────────────────────────
---     ◈  Marius Schaffner added WF:Doing label            09:12
---     ⋯  5 more changes · [<CR>] expand
---   ╭ MS Marius Schaffner  you  ◷ unresolved thread ───── 14:02 ─╮
---   │ The comment body, wrapped to the box width                  │
---   │ 👍 2                                                         │
---   ╰─ [gc] reply · [gE] edit ─────────────────────────────────────╯
---         └─ ╭ AB Anna Berg ──────────────────────────────── 14:30 ─╮
---            │ A reply                                              │
---            ╰──────────────────────────────────────────────────────╯
---
--- Each comment is a box up to 90% of the width; its border and author take
--- the author's colour (`GitlabCommentBorderN` and `GitlabUserN`, see
--- `gg.ui.lib.user_hl`). The bottom border is plain: the view lays the key
--- hints of the comment under the cursor over it (`foot_hint`). Every line
--- carries metadata in `rows` for the view's keys (`<CR>`, `za`).
local avatar = require("gg.ui.lib.avatar")
local date = require("gg.ui.lib.date")
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")
local model = require("gg.ui.detail.activity.model")
local text = require("gg.ui.lib.text")
local user_hl = require("gg.ui.lib.user_hl")

local M = {}

M.RULE = "─"
M.TL, M.TR, M.BL, M.BR, M.V = "╭", "╮", "╰", "╯", "│"
M.TAIL = 1 -- rule cells between the time and the corner
M.BLOCK_SHARE = 0.9
M.REPLY_INDENT = 4

---@class gg.ui.ActivityRenderInput
---@field width integer
---@field status "loading"|"ready"|"error"
---@field items? gg.ui.ActivityItem[]
---@field error? string
---@field state? gg.ui.ActivityState
---@field me? string signed-in username ("you" badge)
---@field utc_offset? integer
---@field user_colors? table<string, string>
---@field keys { expand?: string, fold?: string }

-- split text into verb / object / reference segments
local function event_segments(s)
  local segs = {}
  local pos = 1
  while pos <= #s do
    local b1, b2, bold = s:find("%*%*(.-)%*%*", pos)
    local h1, h2 = s:find("@[%w%._%-]+", pos)
    local r1, r2 = s:find("[%w%._/%-]*[#!&%%~][%w%._/%-]+", pos)
    local first, kind = nil, nil
    for _, c in ipairs({ { b1, "bold" }, { h1, "handle" }, { r1, "ref" } }) do
      if c[1] and (not first or c[1] < first) then
        first, kind = c[1], c[2]
      end
    end
    if not first then
      table.insert(segs, { s:sub(pos), "GitlabTimelineVerb" })
      break
    end
    if first > pos then
      table.insert(segs, { s:sub(pos, first - 1), "GitlabTimelineVerb" })
    end
    if kind == "bold" then
      table.insert(segs, { bold, "GitlabTimelineObject" })
      pos = b2 + 1
    elseif kind == "handle" then
      table.insert(segs, { s:sub(h1, h2), "GitlabTimelineObject" })
      pos = h2 + 1
    else
      table.insert(segs, { s:sub(r1, r2), "GitlabTimelineRef" })
      pos = r2 + 1
    end
  end
  return segs
end
M.event_segments = event_segments

-- `segs` cut to `room` cells
local function fit(segs, room)
  local out, used = {}, 0
  for _, sg in ipairs(segs) do
    local w = text.width(sg[1])
    if used + w > room then
      local rest = room - used
      if rest > 0 then
        table.insert(out, { text.truncate(sg[1], rest), sg[2] })
      end
      return out
    end
    table.insert(out, sg)
    used = used + w
  end
  return out
end

local function day_row(d, item, width)
  local label = " " .. item.label .. " "
  d:line(line.new():add(label, "GitlabTimelineDay"):add(text.rep(M.RULE, width - text.width(label)), "GitlabTimelineRule"), { kind = "day" })
end

local function event_row(d, ev, width)
  local l = line.new():add("   "):add(ev.icon, "GitlabTimelineIcon"):add("  ")
  local time = ev.time or ""
  local room = width - l.cells - text.width(time) - 2
  local segs = { { ev.actor, "GitlabTimelineActor" }, { " ", nil } }
  vim.list_extend(segs, event_segments(text.clean(ev.text)))
  for _, sg in ipairs(fit(segs, math.max(0, room))) do
    l:add(sg[1], sg[2])
  end
  if time ~= "" then
    l:pad_to(width - text.width(time)):add(time, "GitlabTimelineTime")
  end
  d:line(l, { kind = "event", id = ev.id })
end

local function more_row(d, item, keys)
  local l = line.new():add("   "):add("⋯", "GitlabTimelineIcon"):add("  ")
  l:add(("%d more changes"):format(item.count), "GitlabTimelineMore")
  if keys.expand then
    l:add(" · ", "GitlabTimelineMore"):add("[" .. keys.expand .. "]", "GitlabHintKey"):add(" expand", "GitlabTimelineMore")
  end
  d:line(l, { kind = "more", run = item.run })
end

-- a border row: `left`, rule, `right` and `TAIL` rule cells between the
-- corners `a` and `b`, `mid` cells in all. When both labels do not fit the
-- right one goes, then the left one is cut.
local function border_row(l, a, b, left, right, mid, hl)
  l:add(a, hl)
  local lw, rw = 0, 0
  for _, sg in ipairs(left) do
    lw = lw + text.width(sg[1])
  end
  for _, sg in ipairs(right) do
    rw = rw + text.width(sg[1])
  end
  if rw > 0 and lw + 1 + rw + M.TAIL > mid then
    right, rw = {}, 0
  end
  local tail = rw > 0 and M.TAIL or 0
  local used = 0
  for _, sg in ipairs(fit(left, mid - rw - tail)) do
    l:add(sg[1], sg[2] or hl)
    used = used + text.width(sg[1])
  end
  l:add(text.rep(M.RULE, mid - used - rw - tail), hl)
  for _, sg in ipairs(right) do
    l:add(sg[1], sg[2] or hl)
  end
  l:add(text.rep(M.RULE, tail), hl)
  l:add(b, hl)
end

-- one comment (root or reply) as a box: author and badges in the top
-- border, the time on its right, body and reactions inside
---@param ctx table { d, input, indent, width, thread, guide_first, guide_rest, root }
local function comment_block(ctx, note)
  local d, input = ctx.d, ctx.input
  local state = input.state or {}
  local box_w = math.max(14, ctx.width - ctx.indent)
  local inner = box_w - 4 -- between "│ " and " │"
  local author = note.author or {}
  local border = author.username and user_hl.border(author.username, input.user_colors) or "GitlabCommentBorder"
  -- one table on every line of the box: `foot_hint` finds the bottom
  -- border by it (line numbers move when the doc is appended elsewhere)
  local box = { width = box_w }
  local info = { kind = "comment", thread = ctx.thread.id, note = note.id, box = box }
  local first_row = true
  local function open_row()
    local guide = first_row and ctx.guide_first or ctx.guide_rest
    first_row = false
    local l = line.new():add(string.rep(" ", ctx.indent - text.width(guide)))
    if guide ~= "" then
      l:add(guide, "GitlabTimelineGuide")
    end
    return l
  end
  local function emit(segs)
    local l = open_row():add(M.V, border):add(" ")
    for _, sg in ipairs(fit(segs, inner)) do
      l:add(sg[1], sg[2])
    end
    l:pad_to(ctx.indent + box_w - 1):add(M.V, border)
    d:line(l, info)
  end

  -- top border: author and badges left, the time right
  local name = model.display_name(note.author)
  local hl = author.username and user_hl.group(author.username, input.user_colors) or "GitlabTimelineActor"
  local head = {
    { " ", nil },
    { avatar.initials(name), hl },
    { " ", nil },
    { name, hl },
  }
  if input.me and author.username == input.me then
    vim.list_extend(head, { { "  ", nil }, { "you", "GitlabBadgeYou" } })
  end
  if ctx.root then
    local t = ctx.thread
    if t.context then
      vim.list_extend(head, { { "  ", nil }, { "⎇ " .. t.context, "GitlabBadgeContext" } })
    end
    if t.outdated then
      vim.list_extend(head, { { "  ", nil }, { "outdated", "GitlabBadgeOutdated" } })
    end
    if t.resolvable then
      if t.resolved then
        vim.list_extend(head, { { "  ", nil }, { "✓ resolved thread", "GitlabBadgeResolved" } })
      else
        vim.list_extend(head, { { "  ", nil }, { "◷ unresolved thread", "GitlabBadgeUnresolved" } })
      end
    end
  end
  table.insert(head, { " ", nil })
  local right
  if note.pending then
    -- a draft of a review: not sent yet
    right = { { " ", nil }, { "◷ pending", "GitlabBadgePending" }, { " ", nil } }
  else
    right = { { " ", nil }, { date.hhmm(note.created_at, input.utc_offset), "GitlabTimelineTime" }, { " ", nil } }
  end
  local top = open_row()
  border_row(top, M.TL, M.TR, head, right, box_w - 2, border)
  d:line(top, info)

  -- body
  local wrapped = {}
  for _, src in ipairs(model.body_lines(note.body)) do
    vim.list_extend(wrapped, text.wrap(src, inner))
  end
  if #wrapped == 0 then
    wrapped = { "(empty comment)" }
  end
  -- on every line of the box (the table is shared): `za` there shows a
  -- long comment in full or cuts it again, and its hint says which
  local long = #wrapped > model.COMMENT_LINES
  local expanded = long and (state.expanded_notes or {})[note.id] == true
  info.long, info.expanded = long or nil, expanded or nil
  local shown = wrapped
  if long and not expanded then
    shown = vim.list_slice(wrapped, 1, model.COMMENT_LINES)
  end
  for _, s in ipairs(shown) do
    emit({ { s, "GitlabDetailValue" } })
  end
  if #shown < #wrapped then
    emit({ { "…", "GitlabTimelineMore" } })
  end
  -- reactions
  local reactions = model.reactions(note.reactions)
  if #reactions > 0 then
    local segs = {}
    for i, r in ipairs(reactions) do
      if i > 1 then
        table.insert(segs, { "  ", nil })
      end
      table.insert(segs, { r[1], "GitlabReaction" })
      table.insert(segs, { " " .. r[2], "GitlabTimelineMore" })
    end
    emit(segs)
  end

  -- bottom border: plain until the cursor is on the box
  local bottom = open_row()
  box.col = bottom.bytes
  bottom:add(M.BL, border):add(text.rep(M.RULE, box_w - 2), border):add(M.BR, border)
  d:line(bottom, info)
end

--- The key hints of the comment box on line `lnum` of `rows`, laid over
--- its bottom border ("╰─ [gc] reply · [gE] edit ───╯"): the chunks and
--- where they go (1-based line, byte column). Nil when `lnum` is not on a
--- box.
---@param rows table<integer, table> `gg.ui.Doc.rows` of the buffer
---@param lnum integer
---@param chunks gg.ui.Chunk[]
---@return gg.ui.Chunk[]|nil chunks
---@return { lnum: integer, col: integer }|nil at
function M.foot_hint(rows, lnum, chunks)
  local box = rows[lnum] and rows[lnum].box
  if not box then
    return nil
  end
  local foot = lnum
  while rows[foot + 1] and rows[foot + 1].box == box do
    foot = foot + 1
  end
  local segs = { { " ", nil } }
  vim.list_extend(segs, chunks)
  table.insert(segs, { " ", nil })
  -- a corner and one rule cell on each side stay visible
  return fit(segs, math.max(0, box.width - 4)), { lnum = foot, col = box.col + #M.BL + #M.RULE }
end

--- The hints of the comment box under the cursor (`foot_hint`): `parts`
--- (`{ key, description }`, a nil key is left out), then `fold` to show a
--- long comment in full or cut it again. Nil when there is nothing to show.
---@param info table the row under the cursor
---@param lnum integer
---@param rows table<integer, table>|nil
---@param parts { [1]: string|nil, [2]: string }[]
---@param fold string|nil first key of `toggle_fold`
---@return gg.ui.Chunk[]|nil chunks
---@return { lnum: integer, col: integer }|nil at
function M.comment_hint(info, lnum, rows, parts, fold)
  parts = vim.list_extend({}, parts)
  if info.long then
    table.insert(parts, { fold, info.expanded and "collapse" or "expand" })
  end
  local chunks = {}
  for _, p in ipairs(parts) do
    if p[1] then
      if #chunks > 0 then
        table.insert(chunks, { " · ", "GitlabHintText" })
      end
      table.insert(chunks, { "[" .. p[1] .. "]", "GitlabHintKey" })
      table.insert(chunks, { " " .. p[2], "GitlabHintText" })
    end
  end
  if #chunks == 0 then
    return nil
  end
  if info.box and rows then
    return M.foot_hint(rows, lnum, chunks)
  end
  return chunks
end

local function thread_rows(d, thread, input)
  local block_w = math.max(20, math.floor(input.width * M.BLOCK_SHARE))
  comment_block({
    d = d,
    input = input,
    indent = 2,
    width = block_w,
    thread = thread,
    guide_first = "",
    guide_rest = "",
    root = true,
  }, thread.root)
  if thread.folded then
    local l = line.new():add("     "):add(("▸ %d %s"):format(#thread.replies, #thread.replies == 1 and "reply" or "replies"), "GitlabTimelineMore")
    if input.keys.fold then
      l:add(" · ", "GitlabTimelineMore"):add("[" .. input.keys.fold .. "]", "GitlabHintKey"):add(" expand", "GitlabTimelineMore")
    end
    d:line(l, { kind = "replies", thread = thread.id })
  else
    for i, reply in ipairs(thread.replies) do
      local last = i == #thread.replies
      comment_block({
        d = d,
        input = input,
        indent = 2 + M.REPLY_INDENT + 3,
        width = block_w,
        thread = thread,
        guide_first = last and "└─ " or "├─ ",
        guide_rest = last and "   " or "│  ",
        root = false,
      }, reply)
    end
  end
  d:blank({ kind = "gap", thread = thread.id })
end

--- Append one thread (a root comment, its replies, an empty line) to `d`,
--- for views that show threads elsewhere (the review). A note with
--- `pending` is a draft; a thread with `outdated` says so.
---@param d gg.ui.Doc
---@param thread gg.ui.ActivityThread
---@param input gg.ui.ActivityRenderInput
function M.thread(d, thread, input)
  thread_rows(d, thread, input)
end

--- Render the timeline.
---@param input gg.ui.ActivityRenderInput
---@return gg.ui.Doc
function M.render(input)
  local d = doc.new()
  local width = math.max(30, input.width)
  if input.status == "loading" then
    d:text(" Loading activity…", "GitlabDetailMuted")
    return d
  elseif input.status == "error" then
    d:text(" " .. (input.error or "Failed to load the activity"), "GitlabDetailError")
    return d
  end
  local items = input.items or {}
  if #items == 0 then
    d:text(" No activity yet.", "GitlabDetailMuted")
    return d
  end
  for _, item in ipairs(items) do
    if item.kind == "day" then
      if d:count() > 0 then
        d:blank()
      end
      day_row(d, item, width)
    elseif item.kind == "event" then
      event_row(d, item, width)
    elseif item.kind == "more" then
      more_row(d, item, input.keys)
    elseif item.kind == "thread" then
      thread_rows(d, item, input)
    end
  end
  return d
end

--- The collapsed comment box pinned to the bottom of the tab:
--- " MS  › write a new comment…        [i] Comment".
---@param dk { initials: string, key?: string }
---@param width integer inner width of the box
---@return gg.ui.Doc
function M.dock(dk, width)
  local d = doc.new()
  local l = line.new():add(" "):add(" " .. dk.initials .. " ", "GitlabCommentAvatar"):add(" › ", "GitlabDetailMuted")
  l:add("write a new comment…", "GitlabDetailPlaceholder")
  if dk.key then
    local right = "[" .. dk.key .. "] Comment "
    l:pad_to(math.max(l.cells + 2, width - text.width(right)))
    l:add("[" .. dk.key .. "]", "GitlabHintKey"):add(" Comment", "GitlabHintText")
  end
  d:line(l, { kind = "dock" })
  return d
end

return M
