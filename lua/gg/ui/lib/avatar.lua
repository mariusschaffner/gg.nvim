--- People in the detail views: "(MS) Marius Schaffner". Pure.
---
--- The initials take the user's colour (`gg.ui.lib.user_hl`), so a person
--- has the same colour in the tables and in the detail views.
local user_hl = require("gg.ui.lib.user_hl")

local M = {}

--- Two-letter initials: the first letters of the first and last word of
--- `name`, or the first two letters of a single word. Upper case.
---@param name string|nil
---@return string
function M.initials(name)
  local words = {}
  for w in tostring(name or ""):gmatch("[%w\128-\255]+") do
    table.insert(words, w)
  end
  if #words == 0 then
    return "??"
  end
  local function first(w)
    return vim.fn.strcharpart(w, 0, 1)
  end
  local s
  if #words == 1 then
    s = vim.fn.strcharpart(words[1], 0, 2)
  else
    s = first(words[1]) .. first(words[#words])
  end
  return vim.fn.toupper(s)
end

--- Segments `{ text, hl }` for one person: "(MS) Marius Schaffner".
---@param user gg.User|nil
---@param opts? { overrides?: table<string, string>, me?: string, name_hl?: string }
---@return { [1]: string, [2]: string|nil }[]
function M.segments(user, opts)
  opts = opts or {}
  if not user then
    return { { "unknown", "GitlabEmpty" } }
  end
  local name = user.name and user.name ~= "" and user.name or user.username or "?"
  local hl = user.username and user_hl.group(user.username, opts.overrides) or "GitlabEmpty"
  local segs = {
    { "(" .. M.initials(name) .. ")", hl },
    { " ", nil },
    { name, opts.name_hl or "GitlabDetailValue" },
  }
  if opts.me and user.username == opts.me then
    table.insert(segs, { " you", "GitlabBadgeYou" })
  end
  return segs
end

return M
