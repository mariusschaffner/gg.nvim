--- Container registry repositories and tags. Pure.
local gid = require("gg.models.gid")
local util = require("gg.models.util")

local M = {}

---@class gg.ContainerRepository
---@field id integer
---@field name string "" for the project's root image
---@field path string
---@field location string e.g. "registry.example.com/group/project"
---@field tags_count integer|nil
---@field created_at string|nil

---@class gg.ContainerTag
---@field name string
---@field path string|nil
---@field location string|nil
---@field digest string|nil
---@field revision string|nil
---@field short_revision string|nil
---@field total_size integer|nil bytes
---@field created_at string|nil

--- Map a GraphQL ContainerRepository node.
---@param node table|nil
---@return gg.ContainerRepository|nil
function M.repository_from_graphql(node)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  return {
    id = gid.tail(util.value(node.id)),
    name = util.value(node.name),
    path = util.value(node.path),
    location = util.value(node.location),
    tags_count = tonumber(util.value(node.tagsCount)),
    created_at = util.value(node.createdAt),
  }
end

--- Map a REST registry tag.
---@param raw table|nil
---@return gg.ContainerTag|nil
function M.tag_from_rest(raw)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  return {
    name = util.value(raw.name),
    path = util.value(raw.path),
    location = util.value(raw.location),
    digest = util.value(raw.digest),
    revision = util.value(raw.revision),
    short_revision = util.value(raw.short_revision),
    total_size = tonumber(util.value(raw.total_size)),
    created_at = util.value(raw.created_at),
  }
end

return M
