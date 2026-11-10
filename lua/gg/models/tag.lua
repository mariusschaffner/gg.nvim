--- Repository tag model. Pure.
local util = require("gg.models.util")

local M = {}

---@class gg.Tag
---@field name string
---@field commit_sha string|nil
---@field commit_title string|nil
---@field committed_date string|nil ISO 8601
---@field message string|nil the annotation of an annotated tag
---@field protected boolean

--- Map a REST repository tag.
---@param raw table|nil
---@return gg.Tag|nil
function M.from_rest(raw)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local commit = util.value(raw.commit) or {}
  return {
    name = util.value(raw.name),
    commit_sha = util.value(commit.id) or util.value(raw.target),
    commit_title = util.value(commit.title),
    committed_date = util.value(commit.committed_date),
    message = util.value(raw.message),
    protected = util.value(raw.protected) == true,
  }
end

return M
