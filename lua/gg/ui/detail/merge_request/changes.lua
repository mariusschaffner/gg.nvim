--- The Changes tab: one line per changed file with its line counts and a
--- bar, then the totals. Pure.
---
---      FILE                                       ADD    DEL  CHANGE
---      .gitlab-ci.yml                             +27     −9  ■■■■■■■■■■
---      …/roles/webaccess/tasks/main.yml          +112     −0  ■■■■■■■■■■
---   ──────────────────────────────────────────────────────────────────
---      7 files changed                           +297    −41
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")
local text = require("gg.ui.lib.text")

local M = {}

M.BAR = 10
M.CELL = "■"
M.NUM = 6

--- Cells of the bar for one file: scaled to the largest change; a changed
--- file gets at least one cell, and one of each colour when it has both.
---@param add integer
---@param del integer
---@param max integer largest additions + deletions of any file
---@return integer add_cells
---@return integer del_cells
function M.bar_cells(add, del, max)
  local total = add + del
  if total == 0 or max <= 0 then
    return 0, 0
  end
  local cells = math.max(1, math.floor(total / max * M.BAR + 0.5))
  if add > 0 and del > 0 then
    cells = math.max(2, cells)
  end
  local a = math.floor(add / total * cells + 0.5)
  -- one cell of each colour when the file has both kinds of change
  if add > 0 and del > 0 then
    a = math.max(1, math.min(cells - 1, a))
  end
  return a, cells - a
end

--- Split a path for display in `width` cells: the directory is shortened
--- from the left ("…/x/"), then dropped; then the name is cut.
---@param path string
---@param width integer
---@return string dir with its trailing "/" ("" when dropped)
---@return string name
function M.split_path(path, width)
  local dir, name = path:match("^(.*/)([^/]*)$")
  if not dir then
    dir, name = "", path
  end
  if text.width(dir) + text.width(name) <= width then
    return dir, name
  end
  local room = width - text.width(name)
  -- keep whole trailing directories behind "…/"
  local parts = vim.split(dir:sub(1, -2), "/", { plain = true })
  local kept = ""
  for i = #parts, 1, -1 do
    local candidate = parts[i] .. "/" .. kept
    if text.width(text.ELLIPSIS .. "/" .. candidate) > room then
      break
    end
    kept = candidate
  end
  if kept ~= "" then
    return text.ELLIPSIS .. "/" .. kept, name
  end
  if room >= 2 then
    return text.ELLIPSIS .. "/", name
  end
  return "", text.truncate(name, width)
end

---@class gg.ui.ChangesInput
---@field width integer
---@field status "loading"|"ready"|"error"
---@field files? gg.DiffFileStat[]
---@field error? string

--- Render the tab.
---@param input gg.ui.ChangesInput
---@return gg.ui.Doc
function M.render(input)
  local d = doc.new()
  if input.status == "loading" then
    d:text(" Loading changes…", "GitlabDetailMuted")
    return d
  elseif input.status == "error" then
    d:text(" " .. (input.error or "Failed to load the changes"), "GitlabDetailError")
    return d
  end
  local files = input.files or {}
  if #files == 0 then
    d:text(" No changes.", "GitlabDetailMuted")
    return d
  end
  local width = math.max(40, input.width)
  local path_w = width - 3 - (M.NUM + 1) * 2 - 2 - M.BAR - 1
  local max, add_total, del_total = 0, 0, 0
  for _, f in ipairs(files) do
    max = math.max(max, (f.additions or 0) + (f.deletions or 0))
    add_total = add_total + (f.additions or 0)
    del_total = del_total + (f.deletions or 0)
  end
  local function nums(l, a, dl, hl_a, hl_d)
    local sa, sd = "+" .. a, "−" .. dl
    l:add(string.rep(" ", M.NUM + 1 - text.width(sa))):add(sa, hl_a)
    l:add(string.rep(" ", M.NUM + 1 - text.width(sd))):add(sd, hl_d)
  end
  local head = line.new():add("   "):cell("FILE", path_w, "GitlabColumnHeader")
  head:add(string.rep(" ", M.NUM + 1 - 3)):add("ADD", "GitlabColumnHeader")
  head:add(string.rep(" ", M.NUM + 1 - 3)):add("DEL", "GitlabColumnHeader")
  head:add("  "):add("CHANGE", "GitlabColumnHeader")
  d:line(head)
  for _, f in ipairs(files) do
    local a, dl = f.additions or 0, f.deletions or 0
    local l = line.new():add("   ")
    local dir, name = M.split_path(f.path, path_w)
    local start = l.cells
    l:add(dir, "GitlabDetailMuted"):add(name, "GitlabDetailValue")
    l:pad_to(start + path_w)
    nums(l, a, dl, "GitlabDiffAdd", "GitlabDiffDelete")
    l:add("  ")
    local ca, cd = M.bar_cells(a, dl, max)
    l:add(string.rep(M.CELL, ca), "GitlabDiffAdd")
    l:add(string.rep(M.CELL, cd), "GitlabDiffDelete")
    l:add(string.rep(M.CELL, M.BAR - ca - cd), "GitlabProgressTodo")
    d:line(l, { kind = "file", path = f.path })
  end
  d:line(line.new():add(" "):add(text.rep("─", width - 2), "GitlabSeparator"))
  local foot = line.new():add("   ")
  foot:cell(("%d file%s changed"):format(#files, #files == 1 and "" or "s"), path_w, "GitlabDetailMuted")
  nums(foot, add_total, del_total, "GitlabDiffAdd", "GitlabDiffDelete")
  d:line(foot)
  return d
end

return M
