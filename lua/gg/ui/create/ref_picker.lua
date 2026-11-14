--- Choosing a branch or tag: the filtered list of `gg.ui.components.select`
--- with a line per ref (icon, name and, dimmed, the commit).
local chooser = require("gg.ui.components.select")

local M = {}

M.MAX_ROWS = 10
M.MIN_WIDTH = 30
M.ICONS = { branch = "⎇", tag = "◆" }

---@class gg.ui.RefItem
---@field name string
---@field kind "branch"|"tag"
---@field sha? string
---@field title? string the commit title
---@field default? boolean the project's default branch

---@class gg.ui.RefPickerOpts : gg.ui.SelectOpts
---@field load fun(query: string, cb: fun(items: gg.ui.RefItem[])) the matches for `query`
---@field on_pick fun(item: gg.ui.RefItem)
---@field line? nil always `M.line`

--- One line of the list: icon, name and, dimmed, the short SHA and commit title.
---@param item gg.ui.RefItem
---@return string line
---@return { [1]: integer, [2]: integer, [3]: string }[] marks byte ranges and their groups
function M.line(item)
  local head = (" %s %s"):format(M.ICONS[item.kind] or " ", item.name)
  local note = M.note(item)
  local marks = { { 0, #head, item.kind == "tag" and "GitlabRefTag" or (item.default and "GitlabRefDefault" or "GitlabBranchSource") } }
  if note == "" then
    return head, marks
  end
  local line = head .. "  " .. note
  table.insert(marks, { #head, #line, "GitlabCreateDim" })
  return line, marks
end

--- "1a2b3c4d  the commit title" (what is known of it).
---@param item gg.ui.RefItem
---@return string
function M.note(item)
  local parts = {}
  if item.sha then
    table.insert(parts, item.sha:sub(1, 8))
  end
  if item.title and item.title ~= "" then
    table.insert(parts, item.title)
  end
  return table.concat(parts, "  ")
end

--- Open the picker (the prompt takes the focus, in insert mode). Returns
--- nil when it fell back to `vim.ui.select`.
---@param opts gg.ui.RefPickerOpts
---@return gg.ui.Select|nil
function M.open(opts)
  return chooser.open(vim.tbl_extend("force", {
    max_rows = M.MAX_ROWS,
    min_width = M.MIN_WIDTH,
    filetype = "gg_ui_ref",
    key = function(item)
      return item.name
    end,
  }, opts, {
    line = M.line,
    text = function(item)
      return item.name
    end,
  }))
end

return M
