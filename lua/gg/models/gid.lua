--- GraphQL global IDs ("gid://gitlab/Issue/123"). Pure.
local M = {}

--- The last segment of a global ID: a number when numeric, else the string.
--- Plain numbers and numeric strings pass through as numbers.
---@param gid any
---@return integer|string|nil
function M.tail(gid)
  if type(gid) == "number" then
    return gid
  end
  if type(gid) ~= "string" or gid == "" then
    return nil
  end
  local last = gid:match("([^/]+)$") or gid
  return tonumber(last) or last
end

--- The type segment of a global ID ("gid://gitlab/ProjectLabel/1" -> "ProjectLabel").
---@param gid any
---@return string|nil
function M.type(gid)
  if type(gid) ~= "string" then
    return nil
  end
  return gid:match("^gid://gitlab/([^/]+)/")
end

--- Build a global ID.
---@param type_name string e.g. "Issue"
---@param id integer|string
---@return string
function M.build(type_name, id)
  return ("gid://gitlab/%s/%s"):format(type_name, tostring(id))
end

return M
