--- Milestone references (as embedded in issues and merge requests). Pure.
--- Item 6.7 adds the full milestone model.
local gid = require("gg.models.gid")
local util = require("gg.models.util")

local M = {}

---@class gg.MilestoneRef
---@field id integer
---@field iid integer|nil
---@field title string
---@field state string|nil "active" | "closed"
---@field due_date string|nil YYYY-MM-DD
---@field start_date string|nil YYYY-MM-DD
---@field web_url string|nil

--- Map a REST milestone object embedded in an issue/MR.
---@param raw table|nil
---@return gg.MilestoneRef|nil
function M.ref_from_rest(raw)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  return {
    id = tonumber(util.value(raw.id)),
    iid = tonumber(util.value(raw.iid)),
    title = util.value(raw.title),
    state = util.value(raw.state),
    due_date = util.date(raw.due_date),
    start_date = util.date(raw.start_date),
    web_url = util.value(raw.web_url),
  }
end

--- Map a GraphQL Milestone node. `webPath` is joined to the instance origin
--- (not the base URL, so a relative root is never doubled).
---@param node table|nil
---@param ctx? { origin?: string }
---@return gg.MilestoneRef|nil
function M.ref_from_graphql(node, ctx)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  return {
    id = gid.tail(util.value(node.id)),
    iid = tonumber(util.value(node.iid)),
    title = util.value(node.title),
    state = util.value(node.state),
    due_date = util.date(node.dueDate),
    start_date = util.date(node.startDate),
    web_url = util.web_url(node.webPath, ctx and ctx.origin),
  }
end

return M
