--- Draw the activity timeline (`gg.ui.detail.activity.model`). Pure.
---
---  TODAY · 10.11.2026 ─────────────────────────────────────────
---     ◈  Marius Schaffner added WF:Doing label            09:12
---     ⋯  5 more changes · [<CR>] expand
---   ▎ (MS) Marius Schaffner  14:02  you  ◷ unresolved thread
---   ▎ The comment body, wrapped to the block width
---   ▎ 👍 2
---     └─ ▎ (AB) Anna Berg  14:30
---        ▎ A reply
---
--- Comment blocks have a tinted background (`GitlabCommentBg`, replies
--- `GitlabCommentReplyBg`) up to 90% of the width. Every line carries
--- metadata in `rows` for the view's keys (`<CR>`, `za`).
local avatar = require("gg.ui.lib.avatar")
local date = require("gg.ui.lib.date")
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")
local model = require("gg.ui.detail.activity.model")
local text = require("gg.ui.lib.text")
local user_hl = require("gg.ui.lib.user_hl")

local M = {}

M.BAR = "▎"
M.RULE = "─"
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

-- one comment (root or reply): header, body, reactions
---@param ctx table { d, input, indent, width, bg, thread, guide_first, guide_rest, root }
local function comment_block(ctx, note)
  local d, input = ctx.d, ctx.input
  local state = input.state or {}
  local block_w = ctx.width
  local inner = math.max(10, block_w - ctx.indent - 2) -- after the bar and a space
  local bg = ctx.bg
  local info = { kind = "comment", thread = ctx.thread.id, note = note.id }
  local first_row = true
  local function emit(segs, row_info)
    local guide = first_row and ctx.guide_first or ctx.guide_rest
    first_row = false
    local l = line.new():add(string.rep(" ", ctx.indent - text.width(guide)))
    if guide ~= "" then
      l:add(guide, "GitlabTimelineGuide")
    end
    local start = l.bytes
    l:add(M.BAR, "GitlabCommentBar"):add(" ")
    for _, sg in ipairs(fit(segs, inner)) do
      l:add(sg[1], sg[2])
    end
    -- highlighted padding survives the trailing-space trim of `result`
    if block_w > l.cells then
      l:add(string.rep(" ", block_w - l.cells), bg)
    end
    local lnum = d:line(l, row_info or info)
    -- the tint runs from the bar to the end of the block, below other marks
    table.insert(d.marks, { row = lnum - 1, col = start, end_col = l.bytes, hl = bg, priority = 50 })
  end

  -- header
  local author = note.author or {}
  local name = model.display_name(note.author)
  local hl = author.username and user_hl.group(author.username, input.user_colors) or "GitlabTimelineActor"
  local head = {
    { avatar.initials(name), hl },
    { " ", nil },
    { name, hl },
    { "  " .. date.hhmm(note.created_at, input.utc_offset), "GitlabTimelineTime" },
  }
  if input.me and author.username == input.me then
    vim.list_extend(head, { { "  ", nil }, { "you", "GitlabBadgeYou" } })
  end
  if ctx.root then
    local t = ctx.thread
    if t.context then
      vim.list_extend(head, { { "  ", nil }, { "⎇ " .. t.context, "GitlabBadgeContext" } })
    end
    if t.resolvable then
      if t.resolved then
        vim.list_extend(head, { { "  ", nil }, { "✓ resolved thread", "GitlabBadgeResolved" } })
      else
        vim.list_extend(head, { { "  ", nil }, { "◷ unresolved thread", "GitlabBadgeUnresolved" } })
      end
    end
  end
  emit(head)

  -- body
  local wrapped = {}
  for _, src in ipairs(model.body_lines(note.body)) do
    vim.list_extend(wrapped, text.wrap(src, inner))
  end
  if #wrapped == 0 then
    wrapped = { "(empty comment)" }
  end
  local long = #wrapped > model.COMMENT_LINES
  local shown = wrapped
  if long and not (state.expanded_notes or {})[note.id] then
    shown = vim.list_slice(wrapped, 1, model.COMMENT_LINES)
  end
  local truncated = #shown < #wrapped
  local body_info = vim.tbl_extend("force", info, { long = long })
  for _, s in ipairs(shown) do
    emit({ { s, "GitlabDetailValue" } }, body_info)
  end
  if truncated then
    local segs = { { "… ", "GitlabTimelineMore" } }
    if input.keys.fold then
      vim.list_extend(segs, { { "[" .. input.keys.fold .. "]", "GitlabHintKey" }, { " expand", "GitlabTimelineMore" } })
    end
    emit(segs, body_info)
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
end

local function thread_rows(d, thread, input)
  local block_w = math.max(20, math.floor(input.width * M.BLOCK_SHARE))
  comment_block({
    d = d,
    input = input,
    indent = 2,
    width = block_w,
    bg = "GitlabCommentBg",
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
        bg = "GitlabCommentReplyBg",
        thread = thread,
        guide_first = last and "└─ " or "├─ ",
        guide_rest = last and "   " or "│  ",
        root = false,
      }, reply)
    end
  end
  d:blank({ kind = "gap", thread = thread.id })
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
