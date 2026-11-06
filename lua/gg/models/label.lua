--- Label model. Pure.
local gid = require("gg.models.gid")
local util = require("gg.models.util")

local M = {}

---@class gg.Label
---@field id integer|nil
---@field name string
---@field color string|nil "#RRGGBB"
---@field text_color string|nil
---@field description string|nil

--- Map a REST label: a label object, or just a name (issue lists without
--- `with_labels_details`).
---@param raw table|string|nil
---@return gg.Label|nil
function M.from_rest(raw)
  raw = util.value(raw)
  if type(raw) == "string" then
    return { name = raw }
  end
  if type(raw) ~= "table" then
    return nil
  end
  return {
    id = tonumber(util.value(raw.id)),
    name = util.value(raw.name),
    color = util.value(raw.color),
    text_color = util.value(raw.text_color),
    description = util.value(raw.description),
  }
end

--- Map a GraphQL Label node.
---@param node table|nil
---@return gg.Label|nil
function M.from_graphql(node)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  return {
    id = gid.tail(util.value(node.id)),
    name = util.value(node.title),
    color = util.value(node.color),
    text_color = util.value(node.textColor),
    description = util.value(node.description),
  }
end

return M
