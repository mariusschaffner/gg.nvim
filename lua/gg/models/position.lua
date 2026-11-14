--- Diff positions for new comments: validation and builders. Pure.
---
--- GitLab (docs.gitlab.com/api/discussions): an added line is addressed by
--- `new_line` only, a removed line by `old_line` only, an unchanged line by
--- both. A multi-line comment is anchored on its last line and carries a
--- `line_range` whose ends have a line code `<sha1 of the path>_<old>_<new>`.
local bit = require("bit")

local M = {}

---@class gg.NewPosition
---@field new_path string
---@field old_path? string defaults to new_path
---@field new_line? integer
---@field old_line? integer
---@field position_type? "text"|"image"|"file" default "text"
---@field base_sha? string looked up from the latest diff version when missing
---@field start_sha? string
---@field head_sha? string
---@field line_range? table REST line_range for multi-line comments

---@class gg.PositionLine one end of a comment: a line of a diff
---@field old_line integer|nil
---@field new_line integer|nil

local KEYS = {
  new_path = "string",
  old_path = "string",
  new_line = "number",
  old_line = "number",
  position_type = "string",
  base_sha = "string",
  start_sha = "string",
  head_sha = "string",
  line_range = "table",
}

--- Check a position given by a caller.
---@param p any
---@return string|nil key the offending key ("position" or "position.<field>")
---@return string|nil message
function M.check(p)
  if type(p) ~= "table" then
    return "position", "must be a table"
  end
  for k, v in pairs(p) do
    local want = KEYS[k]
    if not want then
      return "position." .. tostring(k), "is not a known position field"
    end
    if type(v) ~= want then
      return "position." .. k, "must be a " .. want
    end
  end
  if type(p.new_path) ~= "string" or p.new_path == "" then
    return "position.new_path", "is required"
  end
  return nil, nil
end

local function word(n)
  return ("%08x"):format(n < 0 and n + 4294967296 or n)
end

--- SHA-1 of a string as 40 hex characters (Neovim has no built-in one).
---@param s string
---@return string
function M.sha1(s)
  local band, bor, bxor, bnot, rol, tobit = bit.band, bit.bor, bit.bxor, bit.bnot, bit.rol, bit.tobit
  local h0, h1, h2, h3, h4 = 0x67452301, tobit(0xEFCDAB89), tobit(0x98BADCFE), 0x10325476, tobit(0xC3D2E1F0)
  local len = #s
  local bits_hi, bits_lo = math.floor(len / 0x20000000), (len * 8) % 4294967296
  s = s .. "\128" .. ("\0"):rep((55 - len) % 64)
    .. string.char(
      math.floor(bits_hi / 16777216) % 256,
      math.floor(bits_hi / 65536) % 256,
      math.floor(bits_hi / 256) % 256,
      bits_hi % 256,
      math.floor(bits_lo / 16777216) % 256,
      math.floor(bits_lo / 65536) % 256,
      math.floor(bits_lo / 256) % 256,
      bits_lo % 256
    )
  local w = {}
  for chunk = 1, #s, 64 do
    for i = 0, 15 do
      local a, b, c, d = s:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d)
    end
    for i = 16, 79 do
      w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif i < 40 then
        f, k = bxor(b, c, d), 0x6ED9EBA1
      elseif i < 60 then
        f, k = bor(band(b, c), band(b, d), band(c, d)), tobit(0x8F1BBCDC)
      else
        f, k = bxor(b, c, d), tobit(0xCA62C1D6)
      end
      local t = tobit(rol(a, 5) + f + e + k + w[i])
      e, d, c, b, a = d, c, rol(b, 30), a, t
    end
    h0, h1, h2, h3, h4 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d), tobit(h4 + e)
  end
  return word(h0) .. word(h1) .. word(h2) .. word(h3) .. word(h4)
end

--- GitLab's line code of a diff line.
---@param path string the file's new path
---@param line gg.PositionLine
---@return string
function M.line_code(path, line)
  return ("%s_%d_%d"):format(M.sha1(path), line.old_line or 0, line.new_line or 0)
end

local function base(paths)
  return { new_path = paths.new_path, old_path = paths.old_path or paths.new_path, position_type = "text" }
end

local function range_end(path, line)
  local kind
  if line.new_line and not line.old_line then
    kind = "new"
  elseif line.old_line and not line.new_line then
    kind = "old"
  end
  return { line_code = M.line_code(path, line), type = kind, old_line = line.old_line, new_line = line.new_line }
end

--- The position of a comment on one line.
---@param paths { new_path: string, old_path?: string }
---@param line gg.PositionLine
---@return gg.NewPosition
function M.line(paths, line)
  local p = base(paths)
  p.old_line, p.new_line = line.old_line, line.new_line
  return p
end

--- The position of a comment on several lines, `first` to `last` in diff
--- order. The comment is anchored on `last`.
---@param paths { new_path: string, old_path?: string }
---@param first gg.PositionLine
---@param last gg.PositionLine
---@return gg.NewPosition
function M.range(paths, first, last)
  local p = M.line(paths, last)
  p.line_range = { start = range_end(paths.new_path, first), ["end"] = range_end(paths.new_path, last) }
  return p
end

--- The position of a comment on a whole file.
---@param paths { new_path: string, old_path?: string }
---@return gg.NewPosition
function M.file(paths)
  local p = base(paths)
  p.position_type = "file"
  return p
end

return M
