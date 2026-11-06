--- Merge request changes: commits, diff files, diff stats, versions. Pure.
local user = require("gg.models.user")
local util = require("gg.models.util")

local M = {}

---@class gg.Commit
---@field sha string
---@field short_sha string|nil
---@field title string|nil
---@field message string|nil
---@field author_name string|nil
---@field author_email string|nil
---@field author gg.User|nil the GitLab user, when the e-mail matches one
---@field authored_date string|nil
---@field committer_name string|nil
---@field committed_date string|nil
---@field web_url string|nil

---@class gg.DiffFile
---@field old_path string
---@field new_path string
---@field a_mode string|nil
---@field b_mode string|nil
---@field diff string "" when collapsed or too large
---@field new_file boolean
---@field renamed_file boolean
---@field deleted_file boolean
---@field generated_file boolean|nil
---@field collapsed boolean|nil
---@field too_large boolean|nil

---@class gg.DiffStat
---@field path string the new path
---@field old_path string|nil set for renames
---@field status "added"|"deleted"|"renamed"|"modified"
---@field additions integer|nil nil when the diff was too large or collapsed
---@field deletions integer|nil

---@class gg.MergeRequestVersion
---@field id integer
---@field head_commit_sha string
---@field base_commit_sha string
---@field start_commit_sha string
---@field created_at string|nil
---@field state string|nil
---@field real_size string|nil
---@field diff_refs gg.DiffRefs the version as diff refs (for positioned comments)

--- Map a GraphQL Commit node.
---@param node table|nil
---@param ctx? { origin?: string }
---@return gg.Commit|nil
function M.commit_from_graphql(node, ctx)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  return {
    sha = util.value(node.sha),
    short_sha = util.value(node.shortId),
    title = util.value(node.title),
    message = util.value(node.message),
    author_name = util.value(node.authorName),
    author_email = util.value(node.authorEmail),
    author = user.from_graphql(node.author, ctx),
    authored_date = util.value(node.authoredDate),
    committer_name = util.value(node.committerName),
    committed_date = util.value(node.committedDate),
    web_url = util.value(node.webUrl),
  }
end

--- Map a REST diff entry (`/merge_requests/:iid/diffs`).
---@param raw table|nil
---@return gg.DiffFile|nil
function M.file_from_rest(raw)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  return {
    old_path = util.value(raw.old_path),
    new_path = util.value(raw.new_path),
    a_mode = util.value(raw.a_mode),
    b_mode = util.value(raw.b_mode),
    diff = util.value(raw.diff) or "",
    new_file = util.value(raw.new_file) == true,
    renamed_file = util.value(raw.renamed_file) == true,
    deleted_file = util.value(raw.deleted_file) == true,
    generated_file = util.value(raw.generated_file),
    collapsed = util.value(raw.collapsed),
    too_large = util.value(raw.too_large),
  }
end

--- Count added and removed lines of a unified diff body. Lines before the
--- first hunk header (`---`/`+++` file headers) are not counted.
---@param diff string
---@return integer additions
---@return integer deletions
function M.count_lines(diff)
  local add, del = 0, 0
  local in_hunk = false
  for line in (diff .. "\n"):gmatch("([^\n]*)\n") do
    if line:sub(1, 2) == "@@" then
      in_hunk = true
    elseif in_hunk then
      local c = line:sub(1, 1)
      if c == "+" then
        add = add + 1
      elseif c == "-" then
        del = del + 1
      end
    end
  end
  return add, del
end

--- The diff stat of a file.
---@param file gg.DiffFile
---@return gg.DiffStat
function M.stat(file)
  local status = "modified"
  if file.new_file then
    status = "added"
  elseif file.deleted_file then
    status = "deleted"
  elseif file.renamed_file then
    status = "renamed"
  end
  local s = {
    path = file.new_path,
    old_path = status == "renamed" and file.old_path or nil,
    status = status,
  }
  if not file.too_large and not file.collapsed and file.diff ~= "" then
    s.additions, s.deletions = M.count_lines(file.diff)
  elseif not file.too_large and not file.collapsed then
    s.additions, s.deletions = 0, 0
  end
  return s
end

--- Map a REST MR diff version (`/merge_requests/:iid/versions`).
---@param raw table|nil
---@return gg.MergeRequestVersion|nil
function M.version_from_rest(raw)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local v = {
    id = tonumber(util.value(raw.id)),
    head_commit_sha = util.value(raw.head_commit_sha),
    base_commit_sha = util.value(raw.base_commit_sha),
    start_commit_sha = util.value(raw.start_commit_sha),
    created_at = util.value(raw.created_at),
    state = util.value(raw.state),
    real_size = util.value(raw.real_size),
  }
  v.diff_refs = { base_sha = v.base_commit_sha, head_sha = v.head_commit_sha, start_sha = v.start_commit_sha }
  return v
end

return M
