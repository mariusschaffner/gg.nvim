--- Small helpers shared by the mappers. Pure.
local M = {}

--- nil for JSON null / vim.NIL / missing.
---@param v any
---@return any
function M.value(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

--- "2026-01-15T00:00:00Z" or "2026-01-15" -> "2026-01-15"; nil stays nil.
---@param v any
---@return string|nil
function M.date(v)
  v = M.value(v)
  if type(v) ~= "string" then
    return nil
  end
  return v:match("^(%d%d%d%d%-%d%d%-%d%d)") or v
end

--- An absolute URL from a web path, given the instance origin
--- ("https://h" + "/gitlab/g/r/-/milestones/1"). Absolute URLs pass through.
---@param path any
---@param origin string|nil
---@return string|nil
function M.web_url(path, origin)
  path = M.value(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if path:match("^%a[%w+%.%-]*://") then
    return path
  end
  if not origin then
    return path
  end
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  return origin .. path
end

--- The project path of a full reference ("group/repo#12" -> "group/repo").
---@param ref any
---@return string|nil
function M.project_of_reference(ref)
  ref = M.value(ref)
  if type(ref) ~= "string" then
    return nil
  end
  return ref:match("^(.-)[#!]%d+$")
end

--- Nodes of a GraphQL connection, or a plain list.
---@param conn any
---@return table[]
function M.nodes(conn)
  conn = M.value(conn)
  if type(conn) ~= "table" then
    return {}
  end
  if conn.nodes ~= nil then
    return M.value(conn.nodes) or {}
  end
  if vim.islist(conn) then
    return conn
  end
  return {}
end

--- True when a GraphQL connection says there are more nodes than returned.
---@param conn any
---@return boolean
function M.has_more(conn)
  conn = M.value(conn)
  return type(conn) == "table" and type(conn.pageInfo) == "table" and conn.pageInfo.hasNextPage == true
end

--- Map a list with `fn`, dropping nils.
---@param list any
---@param fn fun(x: any): any
---@return any[]
function M.map(list, fn)
  local out = {}
  for _, x in ipairs(M.value(list) or {}) do
    local v = fn(x)
    if v ~= nil then
      table.insert(out, v)
    end
  end
  return out
end

--- Lowercase a string (nil stays nil).
---@param v any
---@return string|nil
function M.lower(v)
  v = M.value(v)
  if type(v) ~= "string" then
    return nil
  end
  return v:lower()
end

return M
