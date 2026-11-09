--- One colour per user: a username always maps to the same of the groups
--- `GitlabUser1` … `GitlabUser8` (a stable hash), so a person is recognisable
--- across columns and views. Pure.
local M = {}

M.COUNT = 8
M.CURRENT = "GitlabCurrentUser"

--- djb2 over the bytes of `s`, kept in 32 bits.
---@param s string
---@return integer
function M.hash(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 4294967296
  end
  return h
end

--- The highlight group of `username`; `overrides` pins users to groups.
---@param username string
---@param overrides? table<string, string>
---@return string
function M.group(username, overrides)
  local pinned = overrides and overrides[username]
  if pinned then
    return pinned
  end
  return "GitlabUser" .. (M.hash(username) % M.COUNT + 1)
end

--- A `[text, hl, extra_hl]` item for "@username": the user's colour, and
--- `GitlabCurrentUser` (bold) layered on when it is `me`.
---@param username string
---@param overrides? table<string, string>
---@param me? string the signed-in user's username
---@return gg.ui.LineItem
function M.item(username, overrides, me)
  return { "@" .. username, M.group(username, overrides), (me and username == me) and M.CURRENT or nil }
end

return M
