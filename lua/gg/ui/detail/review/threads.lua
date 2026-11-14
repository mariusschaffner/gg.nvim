--- The threads of a review: published discussions and pending drafts of
--- one file, and where they go in its diff. Pure.
---
--- A draft (`gg.DraftNote`) becomes a note with `pending = true`: a reply
--- when it answers a discussion, a thread of its own otherwise.
local M = {}

---@class gg.ui.ReviewThread : gg.ui.ActivityThread
---@field outdated boolean|nil its position is of an older diff
---@field pending boolean|nil the whole thread is a draft
---@field file_level boolean|nil a comment on the file, not on a line
---@field anchor { old_line: integer|nil, new_line: integer|nil }|nil the line it is on
---@field discussion gg.Discussion|nil

---@class gg.ui.ReviewThreadOpts
---@field me? gg.User the signed-in user (author of the drafts)
---@field folded? table<string, boolean> thread id -> replies hidden

local function comments(d)
  return vim.tbl_filter(function(n)
    return not n.system
  end, d.notes or {})
end

local function on_file(p, file)
  if not p then
    return false
  end
  return (p.new_path ~= nil and p.new_path == file.new_path) or (p.old_path ~= nil and p.old_path == file.old_path)
end

local function is_file_level(p)
  return p.position_type == "file" or (p.old_line == nil and p.new_line == nil)
end

-- "lines 3–5" of a multi-line position
local function range_text(p)
  local s = type(p.line_range) == "table" and p.line_range.start or nil
  if type(s) ~= "table" then
    return nil
  end
  local from = tonumber(s.new_line) or tonumber(s.old_line)
  local to = p.new_line or p.old_line
  if from and to and from ~= to then
    return ("lines %d–%d"):format(math.min(from, to), math.max(from, to))
  end
  return nil
end

--- A draft as a note the comment block can draw.
---@param draft gg.DraftNote
---@param me gg.User|nil
---@return gg.Note
function M.draft_note(draft, me)
  return {
    id = "draft:" .. tostring(draft.id),
    draft_id = draft.id,
    body = draft.note,
    author = me,
    pending = true,
    resolves = draft.resolve_discussion == true,
    position = draft.position,
  }
end

--- The threads of `file`, in the order GitLab returned them, drafts last.
---@param file gg.ui.ReviewFile
---@param discussions gg.Discussion[]|nil
---@param drafts gg.DraftNote[]|nil
---@param opts? gg.ui.ReviewThreadOpts
---@return gg.ui.ReviewThread[]
function M.for_file(file, discussions, drafts, opts)
  opts = opts or {}
  local folded = opts.folded or {}
  local out, by_id = {}, {}
  for _, d in ipairs(discussions or {}) do
    local notes = comments(d)
    local root = notes[1]
    if root and on_file(root.position, file) then
      local p = root.position
      local t = {
        kind = "thread",
        id = d.id,
        root = root,
        replies = vim.list_slice(notes, 2),
        resolvable = d.resolvable == true,
        resolved = d.resolved == true,
        outdated = root.outdated == true or nil,
        file_level = is_file_level(p) or nil,
        anchor = { old_line = p.old_line, new_line = p.new_line },
        context = range_text(p),
        discussion = d,
      }
      table.insert(out, t)
      by_id[d.id] = t
    end
  end
  for _, dr in ipairs(drafts or {}) do
    local note = M.draft_note(dr, opts.me)
    local parent = dr.discussion_id and by_id[dr.discussion_id]
    if parent then
      table.insert(parent.replies, note)
    elseif not dr.discussion_id and on_file(dr.position, file) then
      local p = dr.position
      table.insert(out, {
        kind = "thread",
        id = note.id,
        root = note,
        replies = {},
        resolvable = false,
        resolved = false,
        pending = true,
        file_level = is_file_level(p) or nil,
        anchor = { old_line = p.old_line, new_line = p.new_line },
        context = range_text(p),
      })
    end
  end
  for _, t in ipairs(out) do
    t.folded = folded[t.id] == true and #t.replies > 0
  end
  return out
end

---@class gg.ui.ReviewPlaced
---@field top gg.ui.ReviewThread[] above the diff: file comments, and threads whose line is not shown
---@field at table<integer, gg.ui.ReviewThread[]> row index -> the threads under that row

local function line_text(a)
  local n = a.new_line or a.old_line
  return n and ("line %d"):format(n) or nil
end

--- Put the threads on the rows of a diff. A thread on a line inside a
--- collapsed gap goes under the gap row, one whose line is not in the diff
--- goes to the top; both then say which line they mean.
---@param rows gg.ui.ReviewRow[]
---@param threads gg.ui.ReviewThread[]
---@return gg.ui.ReviewPlaced
function M.place(rows, threads)
  local placed = { top = {}, at = {} }
  for _, t in ipairs(threads) do
    local a = t.anchor or {}
    local index, exact
    if not t.file_level then
      for i, r in ipairs(rows) do
        if r.kind == "line" then
          if a.new_line then
            if r.new_line == a.new_line and r.type ~= "delete" then
              index, exact = i, true
              break
            end
          elseif a.old_line and r.old_line == a.old_line and r.type ~= "add" then
            index, exact = i, true
            break
          end
        elseif r.kind == "gap" then
          if a.new_line then
            if a.new_line >= r.new_line and (r.new_to == nil or a.new_line <= r.new_to) then
              index = i
              break
            end
          elseif a.old_line and a.old_line >= r.old_line and (r.count == nil or a.old_line < r.old_line + r.count) then
            index = i
            break
          end
        end
      end
    end
    if not t.file_level and not exact then
      t.context = t.context or line_text(a)
    end
    if index then
      placed.at[index] = placed.at[index] or {}
      table.insert(placed.at[index], t)
    else
      table.insert(placed.top, t)
    end
  end
  return placed
end

---@class gg.ui.ReviewCounts
---@field threads integer diff threads (published)
---@field unresolved integer
---@field pending integer drafts, general ones included
---@field files table<string, { threads: integer, pending: integer }> by new path

--- Count the threads and drafts of a review, in total and per file.
---@param files gg.ui.ReviewFile[]
---@param discussions gg.Discussion[]|nil
---@param drafts gg.DraftNote[]|nil
---@return gg.ui.ReviewCounts
function M.counts(files, discussions, drafts)
  local c = { threads = 0, unresolved = 0, pending = #(drafts or {}), files = {} }
  local by_new, by_old = {}, {}
  for _, f in ipairs(files) do
    c.files[f.path] = { threads = 0, pending = 0 }
    by_new[f.new_path] = f
    by_old[f.old_path] = f
  end
  local function file_of(p)
    if not p then
      return nil
    end
    return (p.new_path and by_new[p.new_path]) or (p.old_path and by_old[p.old_path]) or nil
  end
  local thread_file = {}
  for _, d in ipairs(discussions or {}) do
    local root = comments(d)[1]
    local f = root and file_of(root.position)
    if f then
      thread_file[d.id] = f
      c.threads = c.threads + 1
      c.files[f.path].threads = c.files[f.path].threads + 1
      if d.resolvable and not d.resolved then
        c.unresolved = c.unresolved + 1
      end
    end
  end
  for _, dr in ipairs(drafts or {}) do
    local f = dr.discussion_id and thread_file[dr.discussion_id] or (not dr.discussion_id and file_of(dr.position)) or nil
    if f then
      c.files[f.path].pending = c.files[f.path].pending + 1
    end
  end
  return c
end

return M
