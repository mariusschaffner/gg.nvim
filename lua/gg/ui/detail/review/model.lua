--- The files of a review and the rows of one file's diff. Pure.
---
--- A file's diff is its hunks with the unchanged lines between them
--- collapsed into gap rows. An expanded gap shows its lines, taken from the
--- file's full content (the new side) when that is loaded:
---
---   gap    ⋯ 39 unchanged lines
---   hunk   @@ -40,7 +40,9 @@ local function request(opts)
---   line   context / delete / add, with old and new line numbers
---   gap    ⋯ unchanged lines below
local gg = require("gg")

local M = {}

---@class gg.ui.ReviewFile
---@field index integer
---@field path string the new path (the old one of a deleted file)
---@field old_path string
---@field new_path string
---@field status "A"|"M"|"D"|"R"
---@field additions integer|nil nil without a diff (too large, collapsed)
---@field deletions integer|nil
---@field hunks gg.DiffHunk[]
---@field unavailable string|nil why there is no diff ("too large", "collapsed", "no text changes")
---@field raw gg.DiffFile

---@class gg.ui.ReviewRow
---@field kind "gap"|"hunk"|"line"
---@field gap? integer gap index (1 = before the first hunk, #hunks + 1 = after the last)
---@field count? integer|nil unchanged lines in a gap (nil: unknown, the content is not loaded)
---@field hunk? integer hunk index
---@field header? string
---@field type? "context"|"add"|"delete"
---@field old_line? integer
---@field new_line? integer
---@field text? string

local function status_of(f)
  if f.new_file then
    return "A"
  elseif f.deleted_file then
    return "D"
  elseif f.renamed_file then
    return "R"
  end
  return "M"
end

--- One review file from a diff file; `hunks` replaces the parsed diff (a
--- diff computed locally for a file GitLab sent without one).
---@param raw gg.DiffFile
---@param index integer
---@param hunks? gg.DiffHunk[]
---@return gg.ui.ReviewFile
function M.file(raw, index, hunks)
  hunks = hunks or gg.diff.parse(raw.diff)
  local f = {
    index = index,
    path = raw.new_path or raw.old_path,
    old_path = raw.old_path or raw.new_path,
    new_path = raw.new_path or raw.old_path,
    status = status_of(raw),
    hunks = hunks,
    raw = raw,
  }
  if #hunks == 0 then
    if raw.too_large then
      f.unavailable = "too large"
    elseif raw.collapsed then
      f.unavailable = "collapsed"
    else
      f.unavailable = "no text changes"
      f.additions, f.deletions = 0, 0
    end
    return f
  end
  local add, del = 0, 0
  for _, h in ipairs(hunks) do
    for _, l in ipairs(h.lines) do
      if l.kind == "add" then
        add = add + 1
      elseif l.kind == "delete" then
        del = del + 1
      end
    end
  end
  f.additions, f.deletions = add, del
  return f
end

--- The review files of a merge request's diff files, in their order.
---@param diffs gg.DiffFile[]
---@return gg.ui.ReviewFile[]
function M.files(diffs)
  local out = {}
  for i, raw in ipairs(diffs or {}) do
    out[i] = M.file(raw, i)
  end
  return out
end

-- the first line a hunk covers on each side, and the first one after it
local function span(h)
  local old_first = h.old_count == 0 and h.old_start + 1 or h.old_start
  local new_first = h.new_count == 0 and h.new_start + 1 or h.new_start
  return old_first, new_first, old_first + h.old_count, new_first + h.new_count
end

---@class gg.ui.ReviewRowsOpts
---@field content? string[] the lines of the file after the change
---@field expanded? table<integer, boolean>|true gap index -> shown in full (true: all)

--- The rows of a file's diff.
---@param file gg.ui.ReviewFile
---@param opts? gg.ui.ReviewRowsOpts
---@return gg.ui.ReviewRow[]
function M.rows(file, opts)
  opts = opts or {}
  local rows = {}
  local content, expanded = opts.content, opts.expanded or {}
  local whole = file.status == "A" or file.status == "D" -- the diff is the whole file
  local function gap(index, old_from, new_from, new_to)
    if whole then
      return false
    end
    local count = new_to and (new_to - new_from + 1) or nil
    if count ~= nil and count <= 0 then
      return false
    end
    local open = expanded == true or expanded[index]
    if open and content then
      local last = new_to or #content
      for n = new_from, last do
        table.insert(rows, { kind = "line", type = "context", old_line = old_from + (n - new_from), new_line = n, text = content[n] or "", gap = index })
      end
      return last >= new_from
    end
    table.insert(rows, { kind = "gap", gap = index, count = count, old_line = old_from, new_line = new_from, new_to = new_to })
    return false
  end
  local next_old, next_new = 1, 1
  for i, h in ipairs(file.hunks) do
    local _, new_first, old_next, new_next = span(h)
    local joined = gap(i, next_old, next_new, new_first - 1)
    if not joined then
      table.insert(rows, { kind = "hunk", hunk = i, header = h.header })
    end
    for _, l in ipairs(h.lines) do
      table.insert(rows, { kind = "line", type = l.kind, old_line = l.old_line, new_line = l.new_line, text = l.text, hunk = i })
    end
    next_old, next_new = old_next, new_next
  end
  if #file.hunks > 0 then
    gap(#file.hunks + 1, next_old, next_new, content and #content or nil)
  end
  return rows
end

--- The gap index of every gap of a file (to expand them all).
---@param file gg.ui.ReviewFile
---@return table<integer, boolean>
function M.all_gaps(file)
  local out = {}
  for i = 1, #file.hunks + 1 do
    out[i] = true
  end
  return out
end

--- The widest line number of the rows (for the gutter).
---@param rows gg.ui.ReviewRow[]
---@return integer
function M.max_line(rows)
  local max = 0
  for _, r in ipairs(rows) do
    max = math.max(max, r.old_line or 0, r.new_line or 0, r.new_to or 0)
  end
  return max
end

--- Totals over the files.
---@param files gg.ui.ReviewFile[]
---@return integer additions
---@return integer deletions
function M.totals(files)
  local a, d = 0, 0
  for _, f in ipairs(files) do
    a, d = a + (f.additions or 0), d + (f.deletions or 0)
  end
  return a, d
end

return M
