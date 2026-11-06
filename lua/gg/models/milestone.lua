--- Milestones: the full model, and the references embedded in issues and
--- merge requests. Pure.
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

---@class gg.Milestone : gg.MilestoneRef
---@field project string|nil full path, for project milestones
---@field group string|nil full path, for group milestones
---@field description string|nil
---@field expired boolean|nil
---@field created_at string|nil
---@field updated_at string|nil

--- Map a REST milestone (project or group milestones API).
---@param raw table|nil
---@param ctx? { project?: string, group?: string }
---@return gg.Milestone|nil
function M.from_rest(raw, ctx)
  local m = M.ref_from_rest(raw)
  if not m then
    return nil
  end
  ctx = ctx or {}
  m.project = util.value(raw.project_id) and ctx.project or nil
  m.group = util.value(raw.group_id) and ctx.group or nil
  m.description = util.value(raw.description)
  m.expired = util.value(raw.expired)
  m.created_at = util.value(raw.created_at)
  m.updated_at = util.value(raw.updated_at)
  return m
end

--- Map a GraphQL Milestone node selected with MilestoneFields. The web URL
--- is the instance origin + webPath (fix: never base_url .. webPath).
---@param node table|nil
---@param ctx? { origin?: string }
---@return gg.Milestone|nil
function M.from_graphql(node, ctx)
  local m = M.ref_from_graphql(node, ctx)
  if not m then
    return nil
  end
  local project, group = util.value(node.project), util.value(node.group)
  m.project = project and util.value(project.fullPath) or nil
  m.group = group and util.value(group.fullPath) or nil
  m.description = util.value(node.description)
  m.expired = util.value(node.expired)
  m.created_at = util.value(node.createdAt)
  m.updated_at = util.value(node.updatedAt)
  return m
end

return M
