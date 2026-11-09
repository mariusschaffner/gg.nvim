--- The shared skeleton of a picker table: a builder for its lines,
--- highlights, separators and row metadata, plus the tabs line, the column
--- header, the rule and the loading / error / empty messages. Pure.
---
--- Every table starts with the same four lines (tabs, blank, column header,
--- rule); the view-specific renderers add their rows with `push`.
local line = require("gg.ui.lib.line")
local tabs = require("gg.ui.components.tabs")
local text = require("gg.ui.lib.text")

local M = {}

M.HEADER_LINES = 4 -- tabs, blank, column header, rule
M.RULE = "─"

---@class gg.ui.Rendered
---@field lines string[]
---@field marks gg.ui.Mark[] 0-based rows, byte columns
---@field virt_lines { row: integer, chunks: gg.ui.Chunk[] }[] 0-based row the lines go below
---@field rows table[] row info indexed by 1-based line number (`kind`, `mark_col`, ...)
---@field blocks table[]
---@field selectable integer[] 1-based line numbers of the selectable rows
---@field columns table the column layout

--- A new, empty output for a table laid out as `cols`.
---@param cols table
---@return gg.ui.Rendered
function M.new(cols)
  return { lines = {}, marks = {}, virt_lines = {}, rows = {}, blocks = {}, selectable = {}, columns = cols }
end

--- Append a finished line with its row info; returns its 1-based line number.
---@param out gg.ui.Rendered
---@param l gg.ui.Line
---@param info table
---@return integer
function M.push(out, l, info)
  local s, marks = l:result()
  table.insert(out.lines, s)
  local row = #out.lines - 1
  for _, m in ipairs(marks) do
    table.insert(out.marks, { row = row, col = m.col, end_col = m.end_col, hl = m.hl })
  end
  out.rows[#out.lines] = info
  return #out.lines
end

--- A thin rule as a virtual line below line `lnum` (never selectable).
---@param out gg.ui.Rendered
---@param lnum integer
function M.separator(out, lnum)
  table.insert(out.virt_lines, { row = lnum - 1, chunks = { { text.rep(M.RULE, out.columns.width), "GitlabSeparator" } } })
end

--- True while the states of `tab` are still loading. `members` maps a tab to
--- its states (default: the tab is its own state; "all" is every pending state).
---@param pending table<string, boolean>|nil
---@param tab string
---@param members? table<string, string[]>
---@return boolean
function M.tab_pending(pending, tab, members)
  if not pending then
    return false
  end
  local states = members and members[tab]
  if not states and tab == "all" then
    for _, v in pairs(pending) do
      if v == true then
        return true
      end
    end
    return false
  end
  for _, s in ipairs(states or { tab }) do
    if pending[s] == true then
      return true
    end
  end
  return false
end

---@class gg.ui.TabsLineOpts
---@field tabs { key: string, label: string }[] in order
---@field active string
---@field counts? table<string, integer> nil while nothing is loaded ("…")
---@field pending? table<string, boolean> loading states: their counts get "…"
---@field members? table<string, string[]> see `tab_pending`
---@field indent? integer default 2
---@field pad? integer default 2
---@field truncated? integer the fetch limit, when it was hit

--- The tabs line: "  Open 9   Closed 3   All 12" with the active tab highlighted.
---@param o gg.ui.TabsLineOpts
---@return gg.ui.Line
function M.tabs_line(o)
  local items = {}
  for _, t in ipairs(o.tabs) do
    local count = o.counts and o.counts[t.key] or nil
    if count and M.tab_pending(o.pending, t.key, o.members) then
      count = count .. "…"
    end
    table.insert(items, { key = t.key, label = t.label, count = count })
  end
  local l = line.new():add(text.rep(" ", o.indent or 2))
  for _, seg in ipairs(tabs.segments(items, o.active, { pad = o.pad or 2 })) do
    l:add(seg[1], seg[2])
  end
  if o.truncated then
    l:add(("  (first %d)"):format(o.truncated), "Comment")
  end
  return l
end

--- The column header: `{ { column, label } }`, hidden (nil) columns skipped.
---@param labels { [1]: gg.ui.Column|nil, [2]: string }[]
---@return gg.ui.Line
function M.header_line(labels)
  local l = line.new()
  for _, pair in ipairs(labels) do
    if pair[1] then
      l:pad_to(pair[1].col)
      l:add(pair[2], "GitlabColumnHeader")
    end
  end
  return l
end

--- Push the four head lines: tabs, blank, header, rule.
---@param out gg.ui.Rendered
---@param tabs_l gg.ui.Line
---@param header_l gg.ui.Line
function M.head(out, tabs_l, header_l)
  M.push(out, tabs_l, { kind = "tabs" })
  M.push(out, line.new(), { kind = "blank" })
  M.push(out, header_l, { kind = "header" })
  M.push(out, line.new():add(text.rep(M.RULE, out.columns.width), "GitlabSeparator"), { kind = "rule" })
end

--- A message line starting at display column `col`.
---@param out gg.ui.Rendered
---@param col integer
---@param s string
---@param hl string
function M.message(out, col, s, hl)
  local l = line.new()
  l:pad_to(col)
  l:add(text.clean(s), hl)
  M.push(out, l, { kind = "message" })
end

---@class gg.ui.StateOpts
---@field status "loading"|"ready"|"error"
---@field noun string "issues", "merge requests"
---@field col integer display column of the messages
---@field has_model boolean something is loaded
---@field empty boolean nothing to show on this page
---@field pending boolean the active tab is still loading
---@field error? string
---@field retry_key? string|false
---@field loaded? integer

--- Push the loading / error / empty message when one applies. Returns true
--- when it did (the caller then has no rows to draw).
---@param out gg.ui.Rendered
---@param o gg.ui.StateOpts
---@return boolean
function M.state(out, o)
  if o.status == "error" then
    M.message(out, o.col, ("Failed to load %s: %s"):format(o.noun, o.error or "unknown error"), "DiagnosticError")
    if o.retry_key then
      local l = line.new()
      l:pad_to(o.col)
      l:add("[" .. o.retry_key .. "]", "GitlabHintKey")
      l:add(" Retry", "GitlabHintText")
      M.push(out, l, { kind = "message" })
    end
    return true
  end
  if o.status == "loading" and not o.has_model then
    local s = ("Loading %s…"):format(o.noun)
    if o.loaded and o.loaded > 0 then
      s = ("%s (%d)"):format(s, o.loaded)
    end
    M.message(out, o.col, s, "Comment")
    return true
  end
  if o.empty then
    M.message(out, o.col, o.pending and ("Loading %s…"):format(o.noun) or ("No %s match"):format(o.noun), "Comment")
    return true
  end
  return false
end

return M
