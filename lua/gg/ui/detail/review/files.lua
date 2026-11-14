--- The files pane of the review: the changed files grouped by directory.
--- Pure.
---
---   lua/gg/core/
---   ✓ task.lua            +2 −2
---   lua/gg/transport/
---   ▸ http.lua    ◷2 💬1 +10 −3
---     retry.lua           +42 A
---
--- `✓` a viewed file, `▸` the file shown, `◷n` pending comments, `💬n`
--- threads, the line counts, and the status of added (A), deleted (D) and
--- renamed (R) files.
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")
local text = require("gg.ui.lib.text")

local M = {}

M.VIEWED = "✓"
M.CURRENT = "▸"
M.PENDING = "◷"
M.THREADS = "💬"

local STATUS_HL = { A = "GitlabDiffAdd", D = "GitlabDiffDelete", R = "GitlabDetailMuted" }

---@class gg.ui.ReviewFilesInput
---@field width integer
---@field status "loading"|"ready"|"error"
---@field error? string
---@field files? gg.ui.ReviewFile[]
---@field current? integer index of the file shown
---@field viewed? table<string, boolean> by path
---@field counts? table<string, { threads: integer, pending: integer }> by path

local function split(path)
  local dir, name = path:match("^(.*/)([^/]*)$")
  if not dir then
    return "", path
  end
  return dir, name
end

-- "…/last/dirs/" in `width` cells
local function short_dir(dir, width)
  if text.width(dir) <= width then
    return dir
  end
  local parts = vim.split(dir:sub(1, -2), "/", { plain = true })
  local kept = ""
  for i = #parts, 1, -1 do
    local candidate = parts[i] .. "/" .. kept
    if text.width(text.ELLIPSIS .. "/" .. candidate) > width then
      break
    end
    kept = candidate
  end
  if kept == "" then
    return text.truncate(dir, width)
  end
  return text.ELLIPSIS .. "/" .. kept
end

--- Render the pane. File rows carry `{ kind = "file", index }`.
---@param input gg.ui.ReviewFilesInput
---@return gg.ui.Doc
function M.render(input)
  local d = doc.new()
  if input.status == "loading" then
    d:text(" Loading…", "GitlabDetailMuted")
    return d
  elseif input.status == "error" then
    d:text(" " .. text.truncate(input.error or "Failed to load", math.max(1, input.width - 2)), "GitlabDetailError")
    return d
  end
  local files = input.files or {}
  if #files == 0 then
    d:text(" No changes.", "GitlabDetailMuted")
    return d
  end
  local width = math.max(16, input.width)
  local viewed, counts = input.viewed or {}, input.counts or {}
  local last_dir
  for _, f in ipairs(files) do
    local dir, name = split(f.path)
    if dir ~= last_dir then
      last_dir = dir
      if dir ~= "" then
        d:line(line.new():add(" "):add(short_dir(dir, width - 2), "GitlabDetailMuted"), { kind = "dir" })
      end
    end
    -- the right side: pending, threads, counts, status
    local right = {}
    local c = counts[f.path] or {}
    if (c.pending or 0) > 0 then
      table.insert(right, { M.PENDING .. c.pending, "GitlabBadgePending" })
    end
    if (c.threads or 0) > 0 then
      table.insert(right, { M.THREADS .. c.threads, "GitlabDetailMuted" })
    end
    if f.additions == nil then
      table.insert(right, { "±?", "GitlabDetailMuted" })
    else
      if f.additions > 0 then
        table.insert(right, { "+" .. f.additions, "GitlabDiffAdd" })
      end
      if f.deletions > 0 then
        table.insert(right, { "−" .. f.deletions, "GitlabDiffDelete" })
      end
    end
    if f.status ~= "M" then
      table.insert(right, { f.status, STATUS_HL[f.status] })
    end
    local right_w = 0
    for _, r in ipairs(right) do
      right_w = right_w + text.width(r[1]) + 1
    end
    local is_current = f.index == input.current
    local l = line.new():add(" ")
    if is_current then
      l:add(M.CURRENT, "GitlabDiffCurrent")
    elseif viewed[f.path] then
      l:add(M.VIEWED, "GitlabDiffViewed")
    else
      l:add(" ")
    end
    l:add(" ")
    local name_w = math.max(4, width - l.cells - right_w - 1)
    local name_hl = is_current and "GitlabDetailTitle" or (viewed[f.path] and "GitlabDetailMuted" or "GitlabDetailValue")
    l:cell(name, name_w, name_hl)
    for _, r in ipairs(right) do
      l:add(" "):add(r[1], r[2])
    end
    d:line(l, { kind = "file", index = f.index, path = f.path })
  end
  return d
end

--- The line of file `index` in a rendered pane.
---@param d gg.ui.Doc
---@param index integer
---@return integer|nil lnum
function M.lnum_of(d, index)
  for lnum = 1, #d.lines do
    local info = d.rows[lnum]
    if info and info.kind == "file" and info.index == index then
      return lnum
    end
  end
  return nil
end

return M
