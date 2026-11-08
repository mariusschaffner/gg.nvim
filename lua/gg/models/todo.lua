--- To-do items. Pure.
local gid = require("gg.models.gid")
local user = require("gg.models.user")
local util = require("gg.models.util")

local M = {}

---@class gg.TodoTarget
---@field iid integer|nil
---@field title string|nil
---@field web_url string|nil

---@class gg.Todo
---@field id integer
---@field action string e.g. "assigned", "mentioned", "review_requested", "build_failed"
---@field target_type string "issue", "merge_request", "commit", "work_item", "epic", "design", "alert", ...
---@field target gg.TodoTarget
---@field target_url string|nil
---@field body string|nil
---@field state "pending"|"done"
---@field project string|nil full path
---@field group string|nil full path
---@field author gg.User|nil
---@field created_at string

local TYPES = {
  issue = "issue",
  mergerequest = "merge_request",
  commit = "commit",
  workitem = "work_item",
  epic = "epic",
  design = "design",
  designmanagementdesign = "design",
  alert = "alert",
  alertmanagementalert = "alert",
}

--- Normalize a target type ("MERGEREQUEST", "MergeRequest" -> "merge_request").
---@param t any
---@return string|nil
function M.target_type(t)
  t = util.value(t)
  if type(t) ~= "string" then
    return nil
  end
  local key = t:lower():gsub("[^%l%d]", "")
  return TYPES[key] or t:lower()
end

--- Map a GraphQL Todo node (TodosList).
---@param node table|nil
---@param ctx? { origin?: string }
---@return gg.Todo|nil
function M.from_graphql(node, ctx)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  local target = util.value(node.target) or {}
  local project, group = util.value(node.project), util.value(node.group)
  return {
    id = gid.tail(util.value(node.id)),
    action = util.value(node.action),
    target_type = M.target_type(node.targetType),
    target = {
      iid = tonumber(util.value(target.iid)),
      title = util.value(target.title) or util.value(target.name),
      web_url = util.value(target.webUrl),
    },
    target_url = util.value(node.targetUrl),
    body = util.value(node.body),
    state = util.value(node.state),
    project = project and util.value(project.fullPath) or nil,
    group = group and util.value(group.fullPath) or nil,
    author = user.from_graphql(node.author, ctx),
    created_at = util.value(node.createdAt),
  }
end

--- Map a REST todo (`/todos`, `mark_as_done`).
---@param raw table|nil
---@param ctx? { origin?: string }
---@return gg.Todo|nil
function M.from_rest(raw, ctx)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local target = util.value(raw.target) or {}
  local project, group = util.value(raw.project), util.value(raw.group)
  return {
    id = tonumber(util.value(raw.id)),
    action = util.value(raw.action_name),
    target_type = M.target_type(raw.target_type),
    target = {
      iid = tonumber(util.value(target.iid)),
      title = util.value(target.title),
      web_url = util.value(target.web_url),
    },
    target_url = util.value(raw.target_url),
    body = util.value(raw.body),
    state = util.value(raw.state),
    project = project and util.value(project.path_with_namespace) or nil,
    group = group and util.value(group.full_path) or nil,
    author = user.from_rest(raw.author, ctx),
    created_at = util.value(raw.created_at),
  }
end

return M
