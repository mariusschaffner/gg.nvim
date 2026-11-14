--- From lines of the diff to the position of a comment. Pure.
---
--- An added line is addressed by its new line number, a removed one by its
--- old one, an unchanged one by both (GitLab's rule). A comment on several
--- lines is anchored on the last one.
local gg = require("gg")

local M = {}

local function ends(info)
  if info.type == "add" then
    return { new_line = info.new_line }
  elseif info.type == "delete" then
    return { old_line = info.old_line }
  end
  return { old_line = info.old_line, new_line = info.new_line }
end

local function paths(file)
  return { new_path = file.new_path, old_path = file.old_path }
end

--- The position of a comment on the diff lines `first` to `last` (row
--- metadata of the rendered diff; the same row twice for one line).
---@param file gg.ui.ReviewFile
---@param first table|nil
---@param last table|nil
---@return gg.NewPosition|nil
---@return string|nil reason why these lines cannot take a comment
function M.lines(file, first, last)
  if not (first and last and first.kind == "line" and last.kind == "line") then
    return nil, "Comments go on lines of the diff"
  end
  if first.index == last.index then
    return gg.diff.line_position(paths(file), ends(last)), nil
  end
  if first.index > last.index then
    first, last = last, first
  end
  return gg.diff.range_position(paths(file), ends(first), ends(last)), nil
end

--- The position of a comment on the whole file.
---@param file gg.ui.ReviewFile
---@return gg.NewPosition
function M.file(file)
  return gg.diff.file_position(paths(file))
end

--- "http.lua:41", "http.lua:41–44" or "http.lua · file": what a comment is on.
---@param file gg.ui.ReviewFile
---@param position gg.NewPosition
---@return string
function M.label(file, position)
  local name = file.path:match("[^/]+$") or file.path
  if position.position_type == "file" then
    return name .. " · file"
  end
  local to = position.new_line or position.old_line
  local s = position.line_range and position.line_range.start
  local from = s and (s.new_line or s.old_line)
  if from and from ~= to then
    return ("%s:%d–%d"):format(name, math.min(from, to), math.max(from, to))
  end
  return ("%s:%d"):format(name, to)
end

return M
