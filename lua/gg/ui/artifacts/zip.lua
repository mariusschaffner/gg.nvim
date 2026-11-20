--- Read the file list of a zip archive from its central directory. Pure:
--- the caller reads the bytes (the tail of the file, then the central
--- directory) and passes them in, so an archive is never read whole.
---
--- 1. `eocd(tail, tail_offset)` finds the end-of-central-directory record in
---    the last bytes of the file (at most TAIL bytes are needed) and returns
---    where the central directory is. For Zip64 archives it reads the Zip64
---    record when the tail holds it, and otherwise asks for it (`need`).
--- 2. `eocd64(bytes)` parses that Zip64 record when it had to be read apart.
--- 3. `entries(cd)` parses the central directory into `{ path, size }`
---    (uncompressed sizes), skipping directory entries.
local M = {}

--- Bytes to read from the end of the file: the record (22) plus the largest
--- comment (65535), plus room for the Zip64 locator and record before it.
M.TAIL = 22 + 65535 + 20 + 56

local SIG_EOCD = "PK\5\6"
local SIG_LOC64 = "PK\6\7"
local SIG_EOCD64 = "PK\6\6"
local SIG_CDH = "PK\1\2"
local MAX16, MAX32 = 0xFFFF, 0xFFFFFFFF

-- little-endian unsigned integer of `n` bytes at 1-based `pos`
local function uint(s, pos, n)
  local v = 0
  for i = n - 1, 0, -1 do
    local b = s:byte(pos + i)
    if not b then
      return nil
    end
    v = v * 256 + b
  end
  return v
end

---@class gg.ui.ZipDirectory
---@field cd_offset integer byte offset of the central directory in the file
---@field cd_size integer its length in bytes
---@field count integer number of entries

---@class gg.ui.ZipNeed
---@field need { offset: integer, length: integer } read these bytes and call `eocd64`

local function parse64(s, pos)
  if s:sub(pos, pos + 3) ~= SIG_EOCD64 or #s < pos + 55 then
    return nil, "bad Zip64 end record"
  end
  return { count = uint(s, pos + 32, 8), cd_size = uint(s, pos + 40, 8), cd_offset = uint(s, pos + 48, 8) }
end

--- Find the central directory from the last bytes of a zip file.
---@param tail string the last bytes of the file (up to TAIL)
---@param tail_offset integer byte offset of `tail` in the file
---@return gg.ui.ZipDirectory|gg.ui.ZipNeed|nil
---@return string|nil error
function M.eocd(tail, tail_offset)
  local pos
  -- search backwards: a comment could contain the signature, the last one wins
  for i = #tail - 21, 1, -1 do
    if tail:sub(i, i + 3) == SIG_EOCD then
      local comment = uint(tail, i + 20, 2)
      if i + 21 + comment <= #tail then
        pos = i
        break
      end
    end
  end
  if not pos then
    return nil, "not a zip archive (no end of central directory)"
  end
  local count = uint(tail, pos + 10, 2)
  local cd_size = uint(tail, pos + 12, 4)
  local cd_offset = uint(tail, pos + 16, 4)
  local loc = pos - 20
  local is64 = count == MAX16 or cd_size == MAX32 or cd_offset == MAX32
  if loc >= 1 and tail:sub(loc, loc + 3) == SIG_LOC64 then
    is64 = true
  end
  if not is64 then
    return { count = count, cd_size = cd_size, cd_offset = cd_offset }
  end
  if loc < 1 or tail:sub(loc, loc + 3) ~= SIG_LOC64 then
    return nil, "Zip64 archive without a locator"
  end
  local rec = uint(tail, loc + 8, 8)
  local in_tail = rec - tail_offset + 1
  if in_tail >= 1 and in_tail + 55 <= #tail then
    return parse64(tail, in_tail)
  end
  return { need = { offset = rec, length = 56 } }
end

--- Parse a Zip64 end-of-central-directory record read apart (see `eocd`).
---@param bytes string
---@return gg.ui.ZipDirectory|nil
---@return string|nil error
function M.eocd64(bytes)
  return parse64(bytes, 1)
end

-- Zip64 extended information: the 64-bit values of the fields set to MAX32
local function zip64_size(extra, uncompressed)
  local p = 1
  while p + 3 <= #extra do
    local id, len = uint(extra, p, 2), uint(extra, p + 2, 2)
    if id == 0x0001 then
      if uncompressed == MAX32 then
        return uint(extra, p + 4, 8)
      end
      return uncompressed
    end
    p = p + 4 + len
  end
  return uncompressed
end

---@class gg.ui.ZipEntry
---@field path string
---@field size integer uncompressed bytes

--- The files listed in a central directory (directories are left out).
---@param cd string the central directory bytes
---@return gg.ui.ZipEntry[]|nil
---@return string|nil error
function M.entries(cd)
  local out = {}
  local p = 1
  while p <= #cd do
    if cd:sub(p, p + 3) ~= SIG_CDH then
      return nil, "corrupt central directory"
    end
    if #cd < p + 45 then
      return nil, "truncated central directory"
    end
    local size = uint(cd, p + 24, 4)
    local name_len, extra_len, comment_len = uint(cd, p + 28, 2), uint(cd, p + 30, 2), uint(cd, p + 32, 2)
    local name_at = p + 46
    if #cd < name_at + name_len + extra_len + comment_len - 1 then
      return nil, "truncated central directory"
    end
    local name = cd:sub(name_at, name_at + name_len - 1):gsub("\\", "/")
    local extra = cd:sub(name_at + name_len, name_at + name_len + extra_len - 1)
    if name ~= "" and name:sub(-1) ~= "/" then
      table.insert(out, { path = name, size = zip64_size(extra, size) })
    end
    p = name_at + name_len + extra_len + comment_len
  end
  return out
end

return M
