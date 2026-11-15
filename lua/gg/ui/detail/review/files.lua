--- The files pane of the review: the changed files as a tree. Pure.
---
---   ▾ lua/gg/
---     ▾ core/
---       ✓ task.lua          +2 −2
---     ▾ transport/
---       ▸ http.lua  ◷2 💬1 +10 −3
---         retry.lua       +42 A
---   ▸ tests/
---     README.md              −1 D
---
--- Directories come before files, both by name; a directory with nothing
--- but one directory in it is joined with it ("lua/gg/"). `▾` / `▸` an open
--- / closed directory, `✓` a viewed file, `▸` before a file the one shown,
--- `◷n` pending comments, `💬n` threads, the line counts, and the status of
--- added (A), deleted (D) and renamed (R) files.
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")
local text = require("gg.ui.lib.text")

local M = {}

M.VIEWED = "✓"
M.CURRENT = "▸"
M.PENDING = "◷"
M.THREADS = "💬"
M.OPEN = "▾"
M.CLOSED = "▸"
M.INDENT = 2

local STATUS_HL = { A = "GitlabDiffAdd", D = "GitlabDiffDelete", R = "GitlabDetailMuted" }

---@class gg.ui.ReviewFilesInput
---@field width integer
---@field status "loading"|"ready"|"error"
---@field error? string
---@field files? gg.ui.ReviewFile[]
---@field current? integer index of the file shown
---@field viewed? table<string, boolean> by path
---@field counts? table<string, { threads: integer, pending: integer }> by path
---@field collapsed? table<string, boolean> directory path -> closed

---@class gg.ui.ReviewTreeRow
---@field kind "dir"|"file"
---@field depth integer
---@field name string
---@field path string a directory's path, or the file's
---@field file? gg.ui.ReviewFile
---@field open? boolean a directory: shown open

local function new_dir(name)
  return { name = name, dirs = {}, files = {} }
end

local function build(files)
  local root = new_dir("")
  for _, f in ipairs(files) do
    local parts = vim.split(f.path, "/", { plain = true })
    local node = root
    for i = 1, #parts - 1 do
      local child = node.dirs[parts[i]]
      if not child then
        child = new_dir(parts[i])
        node.dirs[parts[i]] = child
      end
      node = child
    end
    table.insert(node.files, { name = parts[#parts], file = f })
  end
  return root
end

local function sorted_dirs(node)
  local list = vim.tbl_values(node.dirs)
  table.sort(list, function(a, b)
    return a.name < b.name
  end)
  return list
end

-- a directory that only holds one directory is shown as "a/b"
local function joined(dir)
  local name = dir.name
  while #dir.files == 0 do
    local only = sorted_dirs(dir)
    if #only ~= 1 then
      break
    end
    dir = only[1]
    name = name .. "/" .. dir.name
  end
  return dir, name
end

local function walk(node, depth, prefix, collapsed, out)
  for _, child in ipairs(sorted_dirs(node)) do
    local dir, name = joined(child)
    local path = prefix .. name .. "/"
    local open = not collapsed[path]
    table.insert(out, { kind = "dir", depth = depth, name = name .. "/", path = path, open = open })
    if open then
      walk(dir, depth + 1, path, collapsed, out)
    end
  end
  table.sort(node.files, function(a, b)
    return a.name < b.name
  end)
  for _, f in ipairs(node.files) do
    table.insert(out, { kind = "file", depth = depth, name = f.name, path = f.file.path, file = f.file })
  end
end

--- The rows of the tree, top to bottom.
---@param files gg.ui.ReviewFile[]
---@param collapsed? table<string, boolean>
---@return gg.ui.ReviewTreeRow[]
function M.tree(files, collapsed)
  local out = {}
  walk(build(files), 0, "", collapsed or {}, out)
  return out
end

--- The files in the order the tree shows them, renumbered (`index`), so
--- stepping through the files follows the pane.
---@param files gg.ui.ReviewFile[]
---@return gg.ui.ReviewFile[]
function M.sorted(files)
  local out = {}
  for _, row in ipairs(M.tree(files)) do
    if row.kind == "file" then
      table.insert(out, row.file)
      row.file.index = #out
    end
  end
  return out
end

--- Render the pane. File rows carry `{ kind = "file", index, path }`,
--- directory rows `{ kind = "dir", path }`.
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
  for _, row in ipairs(M.tree(files, input.collapsed)) do
    local l = line.new():add(" " .. string.rep(" ", row.depth * M.INDENT))
    if row.kind == "dir" then
      l:add(row.open and M.OPEN or M.CLOSED, "GitlabDetailMuted"):add(" ")
      l:add(text.truncate(row.name, math.max(4, width - l.cells - 1)), "GitlabDetailMuted")
      d:line(l, { kind = "dir", path = row.path })
    else
      local f = row.file
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
      l:cell(row.name, name_w, name_hl)
      for _, r in ipairs(right) do
        l:add(" "):add(r[1], r[2])
      end
      d:line(l, { kind = "file", index = f.index, path = f.path })
    end
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
