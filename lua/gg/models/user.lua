--- User model. Pure.
local gid = require("gg.models.gid")
local util = require("gg.models.util")

local M = {}

---@class gg.User
---@field id integer
---@field username string
---@field name string
---@field avatar_url string|nil
---@field web_url string|nil
---@field state string|nil "active", "blocked", ...

--- Map a REST user (author, assignee, member, /user).
---@param raw table|nil
---@param ctx? { origin?: string }
---@return gg.User|nil
function M.from_rest(raw, ctx)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  return {
    id = tonumber(util.value(raw.id)),
    username = util.value(raw.username),
    name = util.value(raw.name),
    avatar_url = util.web_url(raw.avatar_url, ctx and ctx.origin),
    web_url = util.value(raw.web_url),
    state = util.value(raw.state),
  }
end

--- Map a GraphQL UserCore / CurrentUser node.
---@param node table|nil
---@param ctx? { origin?: string }
---@return gg.User|nil
function M.from_graphql(node, ctx)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  return {
    id = gid.tail(util.value(node.id)),
    username = util.value(node.username),
    name = util.value(node.name),
    avatar_url = util.web_url(node.avatarUrl, ctx and ctx.origin),
    web_url = util.value(node.webUrl),
    state = util.value(node.state),
  }
end

return M
