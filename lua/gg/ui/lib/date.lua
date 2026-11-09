--- Calendar dates for the UI. Pure: "today" is always passed in.
---
--- Month names are fixed English abbreviations (not `os.date("%b")`, which
--- follows the locale), so output is the same everywhere.
local M = {}

---@class gg.ui.Date
---@field year integer
---@field month integer
---@field day integer

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- Today in local time.
---@return gg.ui.Date
function M.today()
  local t = os.date("*t")
  return { year = t.year, month = t.month, day = t.day }
end

--- "2026-11-20" (or an ISO timestamp starting with a date) -> gg.ui.Date.
---@param s string|nil
---@return gg.ui.Date|nil
function M.parse(s)
  if type(s) ~= "string" then
    return nil
  end
  local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    return nil
  end
  return { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
end

local function stamp(d)
  -- noon avoids DST edges when subtracting
  return os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
end

--- Whole days from `from` to `to` (negative when `to` is earlier).
---@param from gg.ui.Date
---@param to gg.ui.Date
---@return integer
function M.days_between(from, to)
  return math.floor((os.difftime(stamp(to), stamp(from)) / 86400) + 0.5)
end

--- "Nov 20", with the year when it is not `today`'s year ("Jan 05 2027").
---@param d gg.ui.Date
---@param today gg.ui.Date
---@return string
function M.short(d, today)
  local s = ("%s %02d"):format(MONTHS[d.month] or "?", d.day)
  if d.year ~= today.year then
    s = s .. " " .. d.year
  end
  return s
end

---@alias gg.ui.DueTone "normal"|"soon"|"overdue"|"none"

--- Due text for a milestone:
---   > 7 days: "due Nov 20 · in 12d" (normal); 0-7 days: "in 4d" / "today"
---   (soon); past and still open: "2d late" (overdue); past and closed:
---   "due Nov 06" (normal); no date: "no due date" (none).
---@param due string|nil YYYY-MM-DD
---@param today gg.ui.Date
---@param closed? boolean
---@return string text
---@return gg.ui.DueTone tone
function M.due(due, today, closed)
  local d = M.parse(due)
  if not d then
    return "no due date", "none"
  end
  local base = "due " .. M.short(d, today)
  local days = M.days_between(today, d)
  if days < 0 then
    if closed then
      return base, "normal"
    end
    return ("%s · %dd late"):format(base, -days), "overdue"
  elseif days == 0 then
    return base .. " · today", "soon"
  elseif days <= 7 then
    return ("%s · in %dd"):format(base, days), "soon"
  end
  return ("%s · in %dd"):format(base, days), "normal"
end

return M
