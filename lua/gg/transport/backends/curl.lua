--- The real backend: one curl process per request, through `vim.system`.
---
--- Security: the URL, method, headers (including the token) and the body are
--- written to curl's stdin as a config file (`--config -`). Nothing sensitive
--- is on the command line, and there is no argument-size limit.
---
--- Response headers are dumped to stdout ahead of the body (`--dump-header -`)
--- and parsed as they arrive, so a streaming request knows the status before
--- any body byte reaches `on_chunk` (a redirect or error body is never
--- streamed). Redirects are not followed here; transport/http does that.
local errors = require("gg.core.errors")

local M = {}

---@class gg.BackendRequest
---@field method string
---@field url string
---@field headers table<string, string>
---@field body string|nil raw request body
---@field timeout gg.TimeoutConfig
---@field output string|nil stream a 2xx body to this file (written to `<output>.part`, then renamed)
---@field on_chunk fun(data: string)|nil stream a 2xx body to this callback (called on the main loop, in order)
---@field secrets string[]|nil exact secrets to redact from errors
---@field curl_cmd string|nil executable (default "curl")

---@class gg.BackendResponse
---@field status integer
---@field headers table<string, string> lowercase names; repeated headers joined with ", "
---@field body string|nil the body; for streamed 2xx responses nil
---@field bytes integer|nil bytes streamed (output / on_chunk)

-- Error bodies of streamed requests are kept up to this size for messages.
local ERROR_BODY_CAP = 64 * 1024

--- Quote a value for a curl config file.
---@param v string
---@return string
function M.quote(v)
  v = tostring(v):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  return '"' .. v .. '"'
end

--- Build the curl invocation for a request: argv (no secrets) and the stdin config.
---@param req gg.BackendRequest
---@return { argv: string[], stdin: string, part: string|nil }
function M.build(req)
  local stream = req.output ~= nil or req.on_chunk ~= nil
  local argv = {
    req.curl_cmd or "curl",
    "--config",
    "-",
    "--silent",
    "--show-error",
    "--globoff",
    "--suppress-connect-headers",
    "--dump-header",
    "-",
  }
  local part
  if req.output then
    part = req.output .. ".part"
    table.insert(argv, "--output")
    table.insert(argv, part)
  end

  local lines = {}
  local function opt(name, value)
    table.insert(lines, ("%s = %s"):format(name, M.quote(value)))
  end
  opt("url", req.url)
  if req.method and req.method ~= "GET" then
    opt("request", req.method)
  end
  local names = vim.tbl_keys(req.headers or {})
  table.sort(names)
  for _, name in ipairs(names) do
    opt("header", ("%s: %s"):format(name, req.headers[name]))
  end
  if req.body ~= nil then
    opt("data-raw", req.body)
  end
  local t = req.timeout or {}
  if t.connect and t.connect > 0 then
    opt("connect-timeout", tostring(t.connect))
  end
  if stream then
    if t.stall and t.stall > 0 then
      opt("speed-limit", "1")
      opt("speed-time", tostring(t.stall))
    end
  end
  if t.total and t.total > 0 then
    opt("max-time", tostring(t.total))
  end
  return { argv = argv, stdin = table.concat(lines, "\n") .. "\n", part = part }
end

--- Parse one header block ("HTTP/1.1 200 OK\r\nName: value\r\n...").
---@param block string
---@return integer|nil status
---@return table<string, string> headers
function M.parse_header_block(block)
  local headers = {}
  local status
  for line in (block .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    if not status then
      status = tonumber(line:match("^HTTP/[%d%.]+%s+(%d%d%d)"))
    else
      local name, value = line:match("^([^:%s]+)%s*:%s*(.-)%s*$")
      if name then
        name = name:lower()
        if headers[name] then
          headers[name] = headers[name] .. ", " .. value
        else
          headers[name] = value
        end
      end
    end
  end
  return status, headers
end

--- Split a header dump from the data that follows it. Informational (1xx)
--- blocks are skipped. Returns nil while the final block is incomplete.
---@param buf string
---@return { status: integer, headers: table<string,string>, rest: string }|nil
function M.split_headers(buf)
  local pos = 1
  while true do
    local s, e = buf:find("\r\n\r\n", pos, true)
    if not s then
      s, e = buf:find("\n\n", pos, true)
    end
    if not s then
      return nil
    end
    local status, headers = M.parse_header_block(buf:sub(pos, s - 1))
    if status and status >= 100 and status < 200 then
      pos = e + 1
    else
      return { status = status or 0, headers = headers, rest = buf:sub(e + 1) }
    end
  end
end

-- curl exit codes that are about local files, not the network
local LOCAL_EXITS = { [23] = "write error (output file)", [26] = "read error" }

--- Map a curl exit code to a gg.Error.
---@param code integer
---@param stderr string|nil
---@param secrets string[]|nil
---@return gg.Error
function M.exit_error(code, stderr, secrets)
  local msg = (stderr or ""):gsub("%s+$", "")
  if msg == "" then
    msg = "curl exited with code " .. code
  end
  local details = { curl_exit = code }
  if code == 28 then
    return errors.new("timeout", msg, { details = details, secrets = secrets })
  elseif LOCAL_EXITS[code] then
    return errors.new("unknown", msg, { details = details, secrets = secrets })
  end
  return errors.new("network", msg, { details = details, secrets = secrets })
end

local function unlink(path)
  if path then
    vim.uv.fs_unlink(path, function() end)
  end
end

-- Read up to `cap` bytes of a file asynchronously.
local function read_head(path, cap, cb)
  vim.uv.fs_open(path, "r", 438, function(err, fd)
    if err or not fd then
      return cb(nil)
    end
    vim.uv.fs_read(fd, cap, 0, function(_, data)
      vim.uv.fs_close(fd, function() end)
      cb(data)
    end)
  end)
end

-- Move `<output>.part` to `output` (replacing an existing file).
local function finish_output(part, output, cb)
  vim.uv.fs_stat(part, function(_, stat)
    local bytes = stat and stat.size or 0
    vim.uv.fs_unlink(output, function()
      vim.uv.fs_rename(part, output, function(err)
        cb(err == nil, bytes, err)
      end)
    end)
  end)
end

--- Send a request. `on_done` is called once on the main loop, unless the
--- request is cancelled. Returns a cancel function.
---@param req gg.BackendRequest
---@param on_done fun(res: gg.BackendResponse|nil, err: gg.Error|nil)
---@return fun() cancel
function M.send(req, on_done)
  local built = M.build(req)
  local secrets = req.secrets
  local cancelled = false
  local finished = false
  local done = vim.schedule_wrap(function(res, err)
    if cancelled or finished then
      return
    end
    finished = true
    on_done(res, err)
  end)

  -- stdout parsing state
  local head_buf = ""
  local head ---@type { status: integer, headers: table<string,string> }|nil
  local body_parts = {}
  local body_len = 0
  local streamed = 0
  local stream_ok = function()
    return head and head.status >= 200 and head.status < 300
  end

  local function on_body(data)
    if data == "" then
      return
    end
    if req.on_chunk and stream_ok() then
      streamed = streamed + #data
      local cb = req.on_chunk
      vim.schedule(function()
        if not cancelled then
          cb(data)
        end
      end)
    elseif req.on_chunk then
      if body_len < ERROR_BODY_CAP then
        table.insert(body_parts, data)
        body_len = body_len + #data
      end
    else
      table.insert(body_parts, data)
      body_len = body_len + #data
    end
  end

  local function on_stdout(_, data)
    if data == nil or cancelled then
      return
    end
    if head then
      return on_body(data)
    end
    head_buf = head_buf .. data
    local split = M.split_headers(head_buf)
    if split then
      head = { status = split.status, headers = split.headers }
      head_buf = ""
      on_body(split.rest)
    end
  end

  local ok, proc = pcall(vim.system, built.argv, {
    stdin = built.stdin,
    stdout = on_stdout,
    stderr = true,
    text = false,
  }, function(obj)
    if cancelled then
      unlink(built.part)
      return
    end
    if obj.code ~= 0 then
      unlink(built.part)
      return done(nil, M.exit_error(obj.code, obj.stderr, secrets))
    end
    if not head then
      -- headers may still sit in the buffer (no blank line at EOF)
      local status, headers = M.parse_header_block(head_buf)
      if not status then
        unlink(built.part)
        return done(nil, errors.new("network", "no HTTP response received", { secrets = secrets }))
      end
      head = { status = status, headers = headers }
    end
    local res = { status = head.status, headers = head.headers }
    if req.output then
      if stream_ok() then
        finish_output(built.part, req.output, function(moved, bytes, err)
          if not moved then
            unlink(built.part)
            return done(nil, errors.new("unknown", "could not write output file: " .. tostring(err)))
          end
          res.bytes = bytes
          done(res, nil)
        end)
      else
        read_head(built.part, ERROR_BODY_CAP, function(data)
          unlink(built.part)
          res.body = data
          done(res, nil)
        end)
      end
      return
    end
    if req.on_chunk and stream_ok() then
      res.bytes = streamed
    else
      res.body = table.concat(body_parts)
    end
    done(res, nil)
  end)

  if not ok then
    done(nil, errors.new("network", "could not start curl: " .. tostring(proc), { details = { cmd = built.argv[1] } }))
    return function() end
  end

  return function()
    if cancelled or finished then
      return
    end
    cancelled = true
    pcall(proc.kill, proc, 15)
  end
end

return M
