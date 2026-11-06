--- Pagination: offset (REST page numbers), keyset (REST Link headers) and
--- GraphQL cursors, behind one opaque cursor string.
---
--- Resources expose a single-page call returning `gg.Page` (items + cursor)
--- and a collect-all built on `collect`, which requires an upper limit and
--- reports `truncated` when more items existed. Nothing silently returns only
--- the first page.
local errors = require("gg.core.errors")
local task = require("gg.core.task")

local M = {}

M.MAX_PER_PAGE = 100

---@class gg.Page<T>: { items: T[], next_cursor: string|nil }

---@class gg.Collected<T>: { items: T[], truncated: boolean }

--- Clamp a per_page value to [1, 100], with a default.
---@param n any
---@param default integer|nil default 100
---@return integer
function M.per_page(n, default)
  n = tonumber(n) or default or M.MAX_PER_PAGE
  n = math.floor(n)
  if n < 1 then
    n = 1
  end
  return math.min(n, M.MAX_PER_PAGE)
end

--- Parse an RFC 8288 Link header into `{ rel = url }`.
---@param header string|nil
---@return table<string, string>
function M.parse_link(header)
  local out = {}
  if type(header) ~= "string" then
    return out
  end
  for url, params in header:gmatch("<([^>]*)>([^,]*)") do
    for rel in params:gmatch('rel%s*=%s*"?([^";]+)"?') do
      for r in rel:gmatch("%S+") do
        out[r] = url
      end
    end
  end
  return out
end

--- Encode an opaque cursor.
---@param kind "offset"|"keyset"|"graphql"
---@param value string|integer
---@return string
function M.encode(kind, value)
  local prefix = ({ offset = "o", keyset = "k", graphql = "g" })[kind]
  return prefix .. ":" .. tostring(value)
end

--- Decode an opaque cursor.
---@param cursor any
---@return ("offset"|"keyset"|"graphql")|nil kind
---@return string|gg.Error value, or an error
function M.decode(cursor)
  if type(cursor) ~= "string" then
    return nil, errors.new("validation", "cursor must be a string returned by a previous page")
  end
  local p, v = cursor:match("^(%a):(.+)$")
  local kind = ({ o = "offset", k = "keyset", g = "graphql" })[p or ""]
  if not kind then
    return nil, errors.new("validation", "invalid cursor", { details = { cursor = cursor } })
  end
  if kind == "offset" and not tonumber(v) then
    return nil, errors.new("validation", "invalid offset cursor", { details = { cursor = cursor } })
  end
  return kind, v
end

local function page_param(url)
  return url and url:match("[?&]page=(%d+)")
end

--- The next-page cursor of a REST response, or nil on the last page.
--- Offset: `x-next-page`, falling back to `Link rel=next`. Keyset: `Link rel=next`.
---@param headers table<string, string>|nil
---@param mode "offset"|"keyset"
---@return string|nil
function M.rest_next(headers, mode)
  headers = headers or {}
  local links = M.parse_link(headers["link"])
  if mode == "keyset" then
    return links.next and M.encode("keyset", links.next) or nil
  end
  local nxt = headers["x-next-page"]
  if nxt and nxt:match("^%d+$") then
    return M.encode("offset", nxt)
  end
  if nxt == nil and links.next then
    local page = page_param(links.next)
    if page then
      return M.encode("offset", page)
    end
    return M.encode("keyset", links.next)
  end
  return nil
end

--- Resolve a REST cursor: for offset, the page number; for keyset, the URL to
--- fetch (which must be on the instance's own origin).
---@param cursor string|nil
---@param base_origin string origin of the host's base URL
---@param origin_of fun(url: string): string|nil
---@return { page: integer|nil, url: string|nil }|nil
---@return gg.Error|nil
function M.rest_cursor(cursor, base_origin, origin_of)
  if cursor == nil then
    return { page = 1 }, nil
  end
  local kind, value = M.decode(cursor)
  if not kind then
    return nil, value --[[@as gg.Error]]
  end
  if kind == "offset" then
    return { page = tonumber(value) }, nil
  end
  if kind == "keyset" then
    if origin_of(value) ~= base_origin then
      return nil, errors.new("validation", "refusing to follow a next-page link to another origin", {
        details = { origin = origin_of(value) },
      })
    end
    return { url = value }, nil
  end
  return nil, errors.new("validation", "this cursor belongs to a GraphQL list")
end

--- The next-page cursor of a GraphQL connection's pageInfo, or nil.
---@param page_info { hasNextPage: boolean, endCursor: string|nil }|nil
---@return string|nil
function M.graphql_next(page_info)
  if type(page_info) == "table" and page_info.hasNextPage and type(page_info.endCursor) == "string" then
    return M.encode("graphql", page_info.endCursor)
  end
  return nil
end

--- The GraphQL `after` value for a cursor (nil for the first page).
---@param cursor string|nil
---@return string|nil after
---@return gg.Error|nil
function M.graphql_after(cursor)
  if cursor == nil then
    return nil, nil
  end
  local kind, value = M.decode(cursor)
  if not kind then
    return nil, value --[[@as gg.Error]]
  end
  if kind ~= "graphql" then
    return nil, errors.new("validation", "this cursor belongs to a REST list")
  end
  return value --[[@as string]], nil
end

--- Collect items across pages, up to a required limit.
---@param fetch_page fun(args: table, opts: { cursor: string|nil, per_page: integer }): gg.Task resolves with gg.Page
---@param args table
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: any[]) }
---@return gg.Task resolves with gg.Collected
function M.collect(fetch_page, args, opts)
  opts = opts or {}
  local limit = opts.limit
  if type(limit) ~= "number" or limit < 1 or math.floor(limit) ~= limit then
    return task.failed(errors.new("validation", "opts.limit is required: a positive integer upper bound on the items to collect", {
      details = { key = "limit" },
    }))
  end
  if opts.on_page ~= nil and type(opts.on_page) ~= "function" then
    return task.failed(errors.new("validation", "opts.on_page must be a function", { details = { key = "on_page" } }))
  end
  local per_page = math.min(M.per_page(opts.per_page), limit)
  return task.run(function()
    local items = {}
    local cursor = nil
    local seen = {}
    while true do
      local page, err = fetch_page(args, { cursor = cursor, per_page = per_page }):await()
      if err then
        return nil, err
      end
      local got = page.items or {}
      local room = limit - #items
      local take = math.min(room, #got)
      local batch = {}
      for i = 1, take do
        batch[i] = got[i]
        items[#items + 1] = got[i]
      end
      if opts.on_page and #batch > 0 then
        opts.on_page(batch)
      end
      if #items >= limit then
        return { items = items, truncated = (#got > take) or page.next_cursor ~= nil }
      end
      if not page.next_cursor then
        return { items = items, truncated = false }
      end
      if seen[page.next_cursor] then
        return nil, errors.new("unknown", "pagination did not advance (the same cursor came back twice)")
      end
      seen[page.next_cursor] = true
      cursor = page.next_cursor
    end
  end)
end

return M
