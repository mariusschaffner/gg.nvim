--- What changed inside a changed line: the characters that differ between
--- a removed line and the added line that replaced it. Pure.
---
--- In a run of removed lines followed by added lines, the first removed
--- line is compared with the first added one, the second with the second,
--- and so on. Lines that have little in common get no marks (the whole
--- line is tinted already).
local M = {}

M.MAX_CHARS = 400 -- longer lines are not compared
M.MAX_CHANGED = 0.7 -- more than this share of both lines differs: no marks

---@alias gg.ui.ByteRange { [1]: integer, [2]: integer } 0-based start, exclusive end

-- the UTF-8 characters of `s` and the byte offset each one starts at
local function chars(s)
  local list, starts = {}, {}
  for at, ch in s:gmatch("()([%z\1-\127\194-\244][\128-\191]*)") do
    table.insert(list, ch)
    table.insert(starts, at - 1)
  end
  starts[#list + 1] = #s
  return list, starts
end

local function as_lines(list)
  local out = {}
  for i, ch in ipairs(list) do
    -- one character per line; a line break cannot be one of them
    out[i] = ch == "\n" and " " or ch
  end
  return table.concat(out, "\n") .. "\n"
end

local function add_range(ranges, starts, first, count)
  if count <= 0 then
    return 0
  end
  local from, to = starts[first], starts[first + count]
  local last = ranges[#ranges]
  if last and last[2] == from then
    last[2] = to
  else
    table.insert(ranges, { from, to })
  end
  return count
end

--- The byte ranges that differ between `old` and `new`, or nil when the
--- lines are equal, too long or too different to mark.
---@param old string
---@param new string
---@return gg.ui.ByteRange[]|nil old_ranges
---@return gg.ui.ByteRange[]|nil new_ranges
function M.ranges(old, new)
  if old == new or old == "" or new == "" then
    return nil, nil
  end
  local a, a_starts = chars(old)
  local b, b_starts = chars(new)
  if #a > M.MAX_CHARS or #b > M.MAX_CHARS then
    return nil, nil
  end
  local hunks = vim.diff(as_lines(a), as_lines(b), { result_type = "indices", algorithm = "myers" })
  local old_ranges, new_ranges = {}, {}
  local old_changed, new_changed = 0, 0
  for _, h in ipairs(hunks) do
    old_changed = old_changed + add_range(old_ranges, a_starts, h[1], h[2])
    new_changed = new_changed + add_range(new_ranges, b_starts, h[3], h[4])
  end
  if old_changed / #a > M.MAX_CHANGED and new_changed / #b > M.MAX_CHANGED then
    return nil, nil
  end
  return old_ranges, new_ranges
end

--- The changed byte ranges of every row that has a counterpart: rows are
--- the rows of a diff (`gg.ui.ReviewRow`), the result maps a row's index to
--- the ranges inside its text.
---@param rows gg.ui.ReviewRow[]
---@return table<integer, gg.ui.ByteRange[]>
function M.rows(rows)
  local out = {}
  local i, n = 1, #rows
  local function is(r, kind)
    return r ~= nil and r.kind == "line" and r.type == kind
  end
  while i <= n do
    if is(rows[i], "delete") then
      local dels = i
      while is(rows[i], "delete") do
        i = i + 1
      end
      local adds = i
      while is(rows[i], "add") do
        i = i + 1
      end
      for k = 0, math.min(adds - dels, i - adds) - 1 do
        local old_ranges, new_ranges = M.ranges((rows[dels + k].text:gsub("\r", "")), (rows[adds + k].text:gsub("\r", "")))
        if old_ranges then
          out[dels + k], out[adds + k] = old_ranges, new_ranges
        end
      end
    else
      i = i + 1
    end
  end
  return out
end

return M
