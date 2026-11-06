-- A tiny HTTP/1.1 server on 127.0.0.1 for loopback tests of the curl backend.
-- No external network is involved. Test-only code.
local S = {}

local function parse_request(raw)
  local head, body = raw:match("^(.-)\r\n\r\n(.*)$")
  local lines = vim.split(head, "\r\n", { plain = true })
  local method, target = lines[1]:match("^(%u+)%s+(%S+)")
  local headers = {}
  for i = 2, #lines do
    local k, v = lines[i]:match("^([^:]+):%s*(.*)$")
    if k then
      headers[k:lower()] = v
    end
  end
  return { method = method, target = target, path = target:gsub("%?.*$", ""), headers = headers, body = body }
end

local REASONS = { [200] = "OK", [206] = "Partial Content", [302] = "Found", [404] = "Not Found", [500] = "Internal Server Error" }

--- Start a server. `handler(req)` returns { status, headers, body, hang }.
---@param handler fun(req: table): table
---@return { url: string, port: integer, requests: table[], close: fun() }
function S.start(handler)
  local server = assert(vim.uv.new_tcp())
  assert(server:bind("127.0.0.1", 0))
  local port = server:getsockname().port
  local self = { port = port, url = "http://127.0.0.1:" .. port, requests = {}, clients = {} }

  assert(server:listen(16, function(err)
    if err then
      return
    end
    local client = assert(vim.uv.new_tcp())
    server:accept(client)
    table.insert(self.clients, client)
    local buf = ""
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        if not client:is_closing() then
          client:close()
        end
        return
      end
      buf = buf .. chunk
      local s, e = buf:find("\r\n\r\n", 1, true)
      if not s then
        return
      end
      local len = tonumber(buf:sub(1, s):lower():match("content%-length:%s*(%d+)")) or 0
      if #buf - e < len then
        return
      end
      client:read_stop()
      local req = parse_request(buf)
      table.insert(self.requests, req)
      local resp = handler(req) or {}
      if resp.hang then
        return
      end
      local status = resp.status or 200
      local body = resp.body or ""
      local out = { ("HTTP/1.1 %d %s"):format(status, REASONS[status] or "Status") }
      for k, v in pairs(resp.headers or {}) do
        table.insert(out, k .. ": " .. v)
      end
      table.insert(out, "Content-Length: " .. #body)
      table.insert(out, "Connection: close")
      client:write(table.concat(out, "\r\n") .. "\r\n\r\n" .. body, function()
        client:shutdown(function()
          if not client:is_closing() then
            client:close()
          end
        end)
      end)
    end)
  end))

  function self.close()
    for _, c in ipairs(self.clients) do
      if not c:is_closing() then
        c:close()
      end
    end
    if not server:is_closing() then
      server:close()
    end
  end

  return self
end

--- A port with nothing listening (bound, then closed).
---@return integer
function S.closed_port()
  local t = assert(vim.uv.new_tcp())
  assert(t:bind("127.0.0.1", 0))
  local port = t:getsockname().port
  t:close()
  return port
end

return S
