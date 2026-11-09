--- Key hints, always written as "[<key>] <description>". Pure.
local M = {}

---@alias gg.ui.Chunk [string, string] text and highlight group

---@class gg.ui.Hint
---@field key string e.g. "I"
---@field desc string e.g. "Milestone"

--- Chunks for window titles/footers: " [I] Milestone • [i] Issue ".
---@param hints gg.ui.Hint[]
---@param opts? { key_hl?: string, desc_hl?: string, sep?: string, pad?: boolean }
---@return gg.ui.Chunk[]
function M.chunks(hints, opts)
  opts = opts or {}
  local key_hl = opts.key_hl or "GitlabHintKey"
  local desc_hl = opts.desc_hl or "GitlabHintText"
  local sep = opts.sep or " • "
  local out = {}
  local pad = opts.pad ~= false
  if pad then
    table.insert(out, { " ", desc_hl })
  end
  for i, h in ipairs(hints) do
    if i > 1 then
      table.insert(out, { sep, desc_hl })
    end
    table.insert(out, { "[" .. h.key .. "]", key_hl })
    if h.desc and h.desc ~= "" then
      table.insert(out, { " " .. h.desc, desc_hl })
    end
  end
  if pad then
    table.insert(out, { " ", desc_hl })
  end
  return out
end

--- The plain text of one hint: "[R] Retry".
---@param key string
---@param desc string
---@return string
function M.text(key, desc)
  return ("[%s] %s"):format(key, desc)
end

--- Display form of a key for hints ("<CR>" stays, "]m" stays).
---@param lhs string|false
---@return string|nil nil when the mapping is disabled
function M.key(lhs)
  if lhs == false or lhs == nil then
    return nil
  end
  return lhs
end

return M
