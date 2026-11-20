--- Async disk helpers of the artifacts view (vim.uv). Every callback runs on
--- the main loop (scheduled) with `(result, err_message)`.
local uv = vim.uv

local M = {}

local function done(cb)
  return function(...)
    local args = { ... }
    vim.schedule(function()
      cb(unpack(args, 1, 2))
    end)
  end
end

--- The size of a file in bytes; nil (and a message) when it does not exist.
---@param path string
---@param cb fun(size: integer|nil, err: string|nil)
function M.size(path, cb)
  cb = done(cb)
  uv.fs_stat(path, function(err, st)
    if err or not st or st.type ~= "file" then
      return cb(nil, err or "not a file")
    end
    cb(st.size, nil)
  end)
end

--- Read `length` bytes at `offset` (fewer at the end of the file).
---@param path string
---@param offset integer
---@param length integer
---@param cb fun(data: string|nil, err: string|nil)
function M.read(path, offset, length, cb)
  cb = done(cb)
  uv.fs_open(path, "r", 438, function(oerr, fd)
    if oerr or not fd then
      return cb(nil, oerr or "cannot open " .. path)
    end
    uv.fs_read(fd, math.max(0, length), offset, function(rerr, data)
      uv.fs_close(fd, function() end)
      if rerr then
        return cb(nil, rerr)
      end
      cb(data or "", nil)
    end)
  end)
end

--- Create a directory and its parents.
---@param dir string
---@param cb fun(ok: boolean|nil, err: string|nil)
function M.mkdir_p(dir, cb)
  cb = done(cb)
  local function make(d, k)
    uv.fs_mkdir(d, 493, function(err)
      if not err or err:match("^EEXIST") then
        return k(true)
      end
      if err:match("^ENOENT") then
        local parent = vim.fs.dirname(d)
        if parent and parent ~= d then
          return make(parent, function(ok, perr)
            if not ok then
              return k(nil, perr)
            end
            uv.fs_mkdir(d, 493, function(err2)
              if err2 and not err2:match("^EEXIST") then
                return k(nil, err2)
              end
              k(true)
            end)
          end)
        end
      end
      k(nil, err)
    end)
  end
  make(dir, cb)
end

return M
