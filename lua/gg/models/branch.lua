--- Repository branch model. Pure.
local util = require("gg.models.util")

local M = {}

---@class gg.Branch
---@field name string
---@field commit_sha string|nil
---@field commit_title string|nil
---@field committed_date string|nil ISO 8601
---@field default boolean
---@field protected boolean
---@field merged boolean
---@field can_push boolean|nil
---@field web_url string|nil

--- Map a REST branch.
---@param raw table|nil
---@return gg.Branch|nil
function M.from_rest(raw)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local commit = util.value(raw.commit) or {}
  return {
    name = util.value(raw.name),
    commit_sha = util.value(commit.id),
    commit_title = util.value(commit.title),
    committed_date = util.value(commit.committed_date),
    default = util.value(raw.default) == true,
    protected = util.value(raw.protected) == true,
    merged = util.value(raw.merged) == true,
    can_push = util.value(raw.can_push),
    web_url = util.value(raw.web_url),
  }
end

return M
