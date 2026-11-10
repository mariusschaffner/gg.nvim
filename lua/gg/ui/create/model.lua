--- The state of a creation popup that needs no window: border labels, the
--- submit label, the change check, focus order, and which float an API
--- error belongs to. Pure.
local hint = require("gg.ui.lib.hint")
local text = require("gg.ui.lib.text")

local M = {}

M.ERROR_MAX = 48 -- cells of an error shown in the border

---@class gg.ui.CreateSnapshot
---@field title string
---@field body string[]
---@field fields table<string, string>

--- The title float's border label: ` ＋ New issue ` in the accent colour.
---@param def { icon: string, label: string, accent: string }
---@return gg.ui.Chunk[]
function M.title_label(def)
  return { { (" %s %s "):format(def.icon, def.label), def.accent } }
end

--- A float's border label ` [key] Label `, or ` Label ` without a key.
---@param key string|nil
---@param label string
---@return gg.ui.Chunk[]
function M.key_label(key, label)
  if not key then
    return { { (" %s "):format(label), "GitlabCreateHint" } }
  end
  return hint.chunks({ { key = key, desc = label } }, { key_hl = "GitlabCreateKey", desc_hl = "GitlabCreateHint" })
end

--- The body's bottom-left hints: `[<key>] <description>` each; hints
--- without a key (a disabled mapping) are left out.
---@param hints gg.ui.Hint[]
---@return gg.ui.Chunk[]|string
function M.hints(hints)
  local list = vim.tbl_filter(function(h)
    return h.key ~= nil and h.key ~= false
  end, hints)
  if #list == 0 then
    return ""
  end
  return hint.chunks(list, { key_hl = "GitlabCreateKey", desc_hl = "GitlabCreateHint" })
end

---@alias gg.ui.CreateState "idle"|"busy"|"error"

--- The body's bottom-right label: the submit hint, `creating…` while the
--- request runs, or the error.
---@param state gg.ui.CreateState
---@param o { key: string|nil, submit: string, busy: string, error?: string }
---@return gg.ui.Chunk[]
function M.submit_label(state, o)
  if state == "busy" then
    return { { (" %s "):format(o.busy), "GitlabCreateSubmit" } }
  elseif state == "error" then
    return { { (" %s "):format(text.truncate(text.clean(o.error or "failed"), M.ERROR_MAX)), "GitlabCreateError" } }
  end
  if not o.key then
    return { { (" %s "):format(o.submit), "GitlabCreateSubmit" } }
  end
  return { { (" [%s] %s "):format(o.key, o.submit), "GitlabCreateSubmit" } }
end

--- True when anything differs from what the popup opened with.
---@param initial gg.ui.CreateSnapshot
---@param current gg.ui.CreateSnapshot
---@return boolean
function M.dirty(initial, current)
  if initial.title ~= current.title or not vim.deep_equal(initial.fields, current.fields) then
    return true
  end
  return table.concat(initial.body, "\n") ~= table.concat(current.body, "\n")
end

--- The member after (`dir` 1) or before (-1) `current` in `order`, wrapping.
---@param order string[]
---@param current string|nil
---@param dir integer
---@return string|nil
function M.cycle(order, current, dir)
  if #order == 0 then
    return nil
  end
  local idx = 0
  for i, name in ipairs(order) do
    if name == current then
      idx = i
    end
  end
  if idx == 0 then
    return order[1]
  end
  return order[(idx - 1 + dir) % #order + 1]
end

--- Text without trailing blank lines, as GitLab should get it.
---@param lines string[]
---@return string
function M.body_text(lines)
  local last = #lines
  while last > 0 and vim.trim(lines[last]) == "" do
    last = last - 1
  end
  return table.concat(lines, "\n", 1, last)
end

--- The message of an error without the HTTP status in front
--- ("400 Bad Request: title is too long" -> "title is too long").
---@param err gg.Error|string|nil
---@return string
function M.message(err)
  local msg = type(err) == "table" and err.message or tostring(err or "failed")
  return (msg:gsub("^%d%d%d [%a ]-: ", ""))
end

--- Split an API error into the parts that name a float: GitLab answers a
--- rejected field as "title is too long; description is too long". `ids`
--- maps an API field name to a float ("source_branch" -> "source").
---@param err gg.Error|string|nil
---@param ids table<string, string>
---@return table<string, string> by_member messages per float
---@return string[] other the parts that name no float
function M.field_errors(err, ids)
  local by_member, other = {}, {}
  for part in (M.message(err) .. ";"):gmatch("%s*(.-)%s*;") do
    if part ~= "" then
      local field, rest = part:match("^([%w_]+)%s+(.+)$")
      local member = field and ids[field:lower()]
      if member then
        by_member[member] = by_member[member] and (by_member[member] .. "; " .. rest) or rest
      else
        table.insert(other, part)
      end
    end
  end
  return by_member, other
end

--- A date as the user may type it: `2026-11-20` or `20.11.2026`. Returns
--- it as `YYYY-MM-DD`, "" for an empty input, or nil when it is not a date.
---@param s string
---@return string|nil
function M.date(s)
  s = vim.trim(s or "")
  if s == "" then
    return ""
  end
  local y, m, d = s:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
  if not y then
    d, m, y = s:match("^(%d%d?)%.(%d%d?)%.(%d%d%d%d)$")
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if not y or m < 1 or m > 12 or d < 1 or d > 31 then
    return nil
  end
  return ("%04d-%02d-%02d"):format(y, m, d)
end

return M
