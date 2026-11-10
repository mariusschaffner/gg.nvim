--- What a new merge request starts with, and what it must satisfy. Pure.
local M = {}

--- The issue a branch is named after (`22-some-feature` -> 22), or nil.
---@param branch string|nil
---@return integer|nil
function M.issue_iid(branch)
  local n = type(branch) == "string" and branch:match("^(%d+)%-") or nil
  return n and tonumber(n) or nil
end

--- The title a merge request gets by default: the issue's title when the
--- source branch is named after one, else `Merge <source> into <target>`.
---@param source string|nil
---@param target string|nil
---@param issue_title? string
---@return string
function M.title(source, target, issue_title)
  if issue_title and issue_title ~= "" then
    return issue_title
  end
  if not source or source == "" or not target or target == "" then
    return ""
  end
  return ("Merge %s into %s"):format(source, target)
end

--- True when `title` is empty or still the generated `Merge … into …`, so
--- it may follow a changed branch.
---@param title string
---@return boolean
function M.is_generated(title)
  return title == "" or title:match("^Merge %S+ into %S+$") ~= nil
end

--- The description line that closes the issue.
---@param iid integer
---@return string
function M.closes(iid)
  return ("Closes #%d"):format(iid)
end

--- What keeps the form from being sent, or nil. `member` names the float
--- the message belongs to ("title", "source", "target").
---@param form { title: string, source: string|nil, target: string|nil }
---@return string|nil message
---@return string|nil member
function M.validate(form)
  if not form.source or form.source == "" then
    return "Pick a source branch", "source"
  end
  if not form.target or form.target == "" then
    return "Pick a target branch", "target"
  end
  if form.source == form.target then
    return "Source and target branch are the same", "target"
  end
  if vim.trim(form.title or "") == "" then
    return "Title cannot be empty", "title"
  end
  return nil, nil
end

return M
