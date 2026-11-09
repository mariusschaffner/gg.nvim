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

-- days since 1970-01-01 of a proleptic Gregorian date (no os.time: that
-- is local time and platform dependent)
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- the inverse: days since 1970-01-01 -> year, month, day
local function civil_from_days(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return yoe + era * 400 + (m <= 2 and 1 or 0), m, d
end

--- An ISO 8601 timestamp ("2026-11-06T05:30:45Z", "…45.123+01:00") as
--- seconds since the epoch (UTC). A bare date is midnight UTC.
---@param s string|nil
---@return integer|nil
function M.parse_time(s)
  if type(s) ~= "string" then
    return nil
  end
  local y, mo, d, rest = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
  if not y then
    return nil
  end
  local h, mi, sec, tz = rest:match("^[T ](%d%d):(%d%d):(%d%d)%.?%d*(.*)$")
  local t = days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
  if h then
    t = t + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
    local sign, oh, om = tz:match("^([+-])(%d%d):?(%d%d)$")
    if sign then
      local off = tonumber(oh) * 3600 + tonumber(om) * 60
      t = sign == "+" and t - off or t + off
    end
  end
  return t
end

--- The local time's offset from UTC in seconds, now (for `relative`).
---@return integer
function M.utc_offset()
  local now = os.time()
  local utc = os.time(os.date("!*t", now) --[[@as osdateparam]])
  return os.difftime(now, utc)
end

--- Relative time from timestamp `iso` to `now` (epoch seconds): "now",
--- "12s ago", "2m ago", "3h ago", "2d ago"; older than 7 days the date
--- ("Nov 02", in the zone `utc_offset` seconds east of UTC). "" without a
--- timestamp.
---@param iso string|nil
---@param now integer
---@param utc_offset? integer default 0
---@return string
function M.relative(iso, now, utc_offset)
  local t = M.parse_time(iso)
  if not t then
    return ""
  end
  local d = math.max(0, now - t)
  if d < 5 then
    return "now"
  elseif d < 60 then
    return ("%ds ago"):format(d)
  elseif d < 3600 then
    return ("%dm ago"):format(math.floor(d / 60))
  elseif d < 86400 then
    return ("%dh ago"):format(math.floor(d / 3600))
  elseif d <= 7 * 86400 then
    return ("%dd ago"):format(math.floor(d / 86400))
  end
  local _, m, day = civil_from_days(math.floor((t + (utc_offset or 0)) / 86400))
  return ("%s %02d"):format(MONTHS[m], day)
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
