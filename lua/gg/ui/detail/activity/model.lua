--- The activity timeline of an issue or merge request. Pure.
---
--- Discussions (`gg.notes.discussions_all`) hold both comments and system
--- notes. System notes become one-line events; everything else becomes a
--- thread (a root comment and its replies). Entries are sorted oldest
--- first, separated by day dividers, and runs of more than `RUN_MAX`
--- consecutive events collapse to their first and last `RUN_KEEP` around a
--- "N more changes" row until expanded.
local date = require("gg.ui.lib.date")

local M = {}

M.RUN_MAX = 4
M.RUN_KEEP = 2
M.COMMENT_LINES = 8

---@class gg.ui.ActivityState
---@field expanded_runs? table<string, boolean> run key -> shown in full
---@field expanded_notes? table<integer, boolean> note id -> long body shown in full
---@field folded? table<string, boolean> thread id -> replies hidden

---@class gg.ui.ActivityEvent
---@field kind "event"
---@field id integer|nil
---@field icon string
---@field actor string
---@field text string the note's first line, markup removed
---@field time string "HH:MM"

---@class gg.ui.ActivityThread
---@field kind "thread"
---@field id string discussion id
---@field root gg.Note
---@field replies gg.Note[]
---@field resolvable boolean
---@field resolved boolean
---@field context string|nil "path:line" of a diff thread
---@field folded boolean replies hidden

---@alias gg.ui.ActivityItem gg.ui.ActivityEvent|gg.ui.ActivityThread|{ kind: "day", label: string }|{ kind: "more", run: string, count: integer }

-- GitLab system note icon names (and fallback text patterns) -> glyph
local ICONS = {
  { "@", { "user", "assignee", "reviewer" }, { "^assigned", "^unassigned", "requested review", "removed review" } },
  { "⇄", { "arrow%-right", "moved" }, { "^moved", "^cloned" } },
  { "☑", { "task%-done" }, { "as completed", "^checked" } },
  { "☐", { "list%-task" }, { "as incomplete", "^unchecked" } },
  { "✎", { "pencil" }, { "changed the description", "changed title", "^changed the title", "^edited" } },
  { "◈", { "label" }, { "label" } },
  { "◆", { "milestone" }, { "milestone" } },
  { "✕", { "status_closed", "issue%-close", "close" }, { "^closed" } },
  { "↺", { "status_open", "issue%-reopen", "reopen" }, { "^reopened" } },
  { "⇣", { "git%-merge" }, { "^merged" } },
  { "✓", { "approval", "check" }, { "^approved" } },
  { "↗", { "comment%-dots", "mention" }, { "^mentioned in" } },
  { "⇢", { "link", "issues" }, { "related to", "^marked this issue as", "blocks", "^linked" } },
  { "◷", { "timer", "time%-out", "hourglass" }, { "time spent", "time estimate" } },
  { "▦", { "calendar" }, { "due date", "start date" } },
  { "⎇", { "fork", "branch", "commit" }, { "branch", "^added %d+ commit", "commit" } },
  { "⊘", { "lock" }, { "^locked", "^unlocked" } },
  { "◌", { "eye%-slash", "confidential" }, { "confidential" } },
}
M.DEFAULT_ICON = "•"

--- The glyph of a system note.
---@param icon_name string|nil GitLab's `systemNoteIconName`
---@param text string the note's text
---@return string
function M.icon(icon_name, text)
  local name = (icon_name or ""):lower()
  local body = (text or ""):lower()
  if name ~= "" then
    for _, e in ipairs(ICONS) do
      for _, p in ipairs(e[2]) do
        if name:find(p) then
          return e[1]
        end
      end
    end
  end
  for _, e in ipairs(ICONS) do
    for _, p in ipairs(e[3]) do
      if body:find(p) then
        return e[1]
      end
    end
  end
  return M.DEFAULT_ICON
end

--- Markdown and HTML a comment shows as plain text: HTML comments and tags
--- go, `[text](url)` becomes `text`.
---@param s string|nil
---@return string
function M.strip_markup(s)
  s = tostring(s or ""):gsub("\r", "")
  s = s:gsub("<!%-%-.-%-%->", "")
  s = s:gsub("!?%[([^%]]*)%]%(([^%)]*)%)", "%1")
  s = s:gsub("</?[%a][^>]*>", "")
  return s
end

--- The one-line text of a system note: the first line without markup;
--- checklist changes shortened to "checked X" / "unchecked X".
---@param body string|nil
---@return string
function M.event_text(body)
  local first = M.strip_markup(body):match("^%s*([^\n]*)") or ""
  first = first:gsub("%s+$", "")
  local item = first:match("^marked the checklist item (.-) as completed$")
  if item then
    return "checked " .. item
  end
  item = first:match("^marked the checklist item (.-) as incomplete$")
  if item then
    return "unchecked " .. item
  end
  return first
end

--- The lines of a comment body: markup removed, trailing blank lines gone.
---@param body string|nil
---@return string[]
function M.body_lines(body)
  local lines = vim.split(M.strip_markup(body), "\n", { plain = true })
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  return lines
end

local function display_name(user)
  if not user then
    return "someone"
  end
  return (user.name and user.name ~= "") and user.name or user.username or "someone"
end
M.display_name = display_name

-- "path:line" of a diff note
local function context_of(note)
  local p = note.position
  if not p then
    return nil
  end
  local path = p.new_path or p.old_path
  if not path then
    return nil
  end
  local ln = p.new_line or p.old_line
  return ln and ("%s:%d"):format(path, ln) or path
end

---@class gg.ui.ActivityOpts
---@field state? gg.ui.ActivityState
---@field utc_offset? integer local zone, seconds east of UTC
---@field today gg.ui.Date

-- one sortable entry per event or thread
local function entries(discussions)
  local out = {}
  for _, d in ipairs(discussions or {}) do
    local notes = d.notes or {}
    local comments = vim.tbl_filter(function(n)
      return not n.system
    end, notes)
    if #comments == 0 then
      for _, n in ipairs(notes) do
        table.insert(out, { kind = "event", note = n, at = date.parse_time(n.created_at) or 0 })
      end
    else
      local root = comments[1]
      table.insert(out, {
        kind = "thread",
        discussion = d,
        root = root,
        replies = vim.list_slice(comments, 2),
        at = date.parse_time(root.created_at) or 0,
      })
    end
  end
  for i, e in ipairs(out) do
    e.order = i
  end
  table.sort(out, function(a, b)
    if a.at ~= b.at then
      return a.at < b.at
    end
    if a.kind ~= b.kind then
      return a.kind == "event" -- activity before comments at the same moment
    end
    return a.order < b.order
  end)
  return out
end

--- Build the timeline.
---@param discussions gg.Discussion[]
---@param opts gg.ui.ActivityOpts
---@return gg.ui.ActivityItem[]
function M.build(discussions, opts)
  local state = opts.state or {}
  local expanded_runs = state.expanded_runs or {}
  local folded = state.folded or {}
  local items = {}
  local run = {}
  local function flush_run()
    if #run == 0 then
      return
    end
    local key = tostring(run[1].id or run[1].time)
    if #run > M.RUN_MAX and not expanded_runs[key] then
      for i = 1, M.RUN_KEEP do
        table.insert(items, run[i])
      end
      table.insert(items, { kind = "more", run = key, count = #run - 2 * M.RUN_KEEP })
      for i = #run - M.RUN_KEEP + 1, #run do
        table.insert(items, run[i])
      end
    else
      vim.list_extend(items, run)
    end
    run = {}
  end
  local last_day
  for _, e in ipairs(entries(discussions)) do
    local created = e.kind == "event" and e.note.created_at or e.root.created_at
    local day = date.local_day(created, opts.utc_offset)
    if day and not date.same_day(day, last_day) then
      flush_run()
      table.insert(items, { kind = "day", label = date.day_label(day, opts.today) })
      last_day = day
    end
    if e.kind == "event" then
      local text = M.event_text(e.note.body)
      table.insert(run, {
        kind = "event",
        id = e.note.id,
        icon = M.icon(e.note.system_note_icon_name, text),
        actor = display_name(e.note.author),
        text = text,
        time = date.hhmm(e.note.created_at, opts.utc_offset),
      })
    else
      flush_run()
      local d = e.discussion
      table.insert(items, {
        kind = "thread",
        id = d.id,
        root = e.root,
        replies = e.replies,
        resolvable = d.resolvable == true,
        resolved = d.resolved == true,
        context = context_of(e.root),
        folded = folded[d.id] == true and #e.replies > 0,
      })
    end
  end
  flush_run()
  return items
end

-- common GitLab award names -> emoji
local EMOJI = {
  thumbsup = "👍",
  thumbsdown = "👎",
  ["+1"] = "👍",
  ["-1"] = "👎",
  heart = "❤",
  tada = "🎉",
  smile = "😄",
  laughing = "😆",
  rocket = "🚀",
  eyes = "👀",
  white_check_mark = "✅",
  heavy_check_mark = "✔",
  fire = "🔥",
  pray = "🙏",
  confused = "😕",
  thinking = "🤔",
  clap = "👏",
  ok_hand = "👌",
  ["100"] = "💯",
}

--- Reactions as `{ glyph, count }`, most frequent first (ties: by name).
---@param reactions gg.Reaction[]|nil
---@return { [1]: string, [2]: integer }[]
function M.reactions(reactions)
  local counts, order = {}, {}
  for _, r in ipairs(reactions or {}) do
    if r.name then
      if not counts[r.name] then
        table.insert(order, r.name)
        counts[r.name] = 0
      end
      counts[r.name] = counts[r.name] + 1
    end
  end
  table.sort(order, function(a, b)
    if counts[a] ~= counts[b] then
      return counts[a] > counts[b]
    end
    return a < b
  end)
  return vim.tbl_map(function(name)
    return { EMOJI[name] or (":" .. name .. ":"), counts[name] }
  end, order)
end

return M
