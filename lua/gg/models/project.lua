--- Project model. Pure.
local gid = require("gg.models.gid")
local util = require("gg.models.util")

local M = {}

---@class gg.Project
---@field id integer
---@field name string
---@field path string
---@field full_path string "group/sub/project"
---@field description string|nil
---@field default_branch string|nil
---@field visibility string|nil "public" | "internal" | "private"
---@field web_url string|nil
---@field last_activity_at string|nil
---@field archived boolean|nil

--- Map a GraphQL Project node (ProjectFields).
---@param node table|nil
---@return gg.Project|nil
function M.from_graphql(node)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  local repo = util.value(node.repository)
  return {
    id = gid.tail(util.value(node.id)),
    name = util.value(node.name),
    path = util.value(node.path),
    full_path = util.value(node.fullPath),
    description = util.value(node.description),
    default_branch = repo and util.value(repo.rootRef) or nil,
    visibility = util.value(node.visibility),
    web_url = util.value(node.webUrl),
    last_activity_at = util.value(node.lastActivityAt),
    archived = util.value(node.archived),
  }
end

return M
