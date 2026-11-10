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

--- Short age of timestamp `iso` at `now`: "now", "12s", "5m", "3h", "2d",
--- "3w", "4mo", "2y" ("" without a timestamp).
---@param iso string|nil
---@param now integer epoch seconds
---@return string
function M.age(iso, now)
  local t = M.parse_time(iso)
  if not t then
    return ""
  end
  local d = math.max(0, now - t)
  if d < 5 then
    return "now"
  elseif d < 60 then
    return ("%ds"):format(d)
  elseif d < 3600 then
    return ("%dm"):format(math.floor(d / 60))
  elseif d < 86400 then
    return ("%dh"):format(math.floor(d / 3600))
  elseif d < 7 * 86400 then
    return ("%dd"):format(math.floor(d / 86400))
  elseif d < 30 * 86400 then
    return ("%dw"):format(math.floor(d / (7 * 86400)))
  elseif d < 365 * 86400 then
    return ("%dmo"):format(math.floor(d / (30 * 86400)))
  end
  return ("%dy"):format(math.floor(d / (365 * 86400)))
end

--- Local calendar day of timestamp `iso` (shifted `utc_offset` seconds east
--- of UTC).
---@param iso string|nil
---@param utc_offset? integer
---@return gg.ui.Date|nil
function M.local_day(iso, utc_offset)
  local t = M.parse_time(iso)
  if not t then
    return nil
  end
  local y, m, d = civil_from_days(math.floor((t + (utc_offset or 0)) / 86400))
  return { year = y, month = m, day = d }
end

--- Local "HH:MM" of timestamp `iso` ("" without a timestamp).
---@param iso string|nil
---@param utc_offset? integer
---@return string
function M.hhmm(iso, utc_offset)
  local t = M.parse_time(iso)
  if not t then
    return ""
  end
  local s = (t + (utc_offset or 0)) % 86400
  return ("%02d:%02d"):format(math.floor(s / 3600), math.floor(s % 3600 / 60))
end

--- "DD.MM.YYYY".
---@param d gg.ui.Date
---@return string
function M.dotted(d)
  return ("%02d.%02d.%04d"):format(d.day, d.month, d.year)
end

--- "DD.MM." (no year).
---@param d gg.ui.Date
---@return string
function M.dotted_short(d)
  return ("%02d.%02d."):format(d.day, d.month)
end

--- A day divider label: "TODAY · 10.11.2026", "YESTERDAY · 09.11.2026" or
--- "05.11.2026".
---@param d gg.ui.Date
---@param today gg.ui.Date
---@return string
function M.day_label(d, today)
  local diff = M.days_between(d, today)
  if diff == 0 then
    return "TODAY · " .. M.dotted(d)
  elseif diff == 1 then
    return "YESTERDAY · " .. M.dotted(d)
  end
  return M.dotted(d)
end

--- True when both dates are the same day.
---@param a gg.ui.Date|nil
---@param b gg.ui.Date|nil
---@return boolean
function M.same_day(a, b)
  return a ~= nil and b ~= nil and a.year == b.year and a.month == b.month and a.day == b.day
end

--- A duration in seconds as a clock: "12s", "1:02", "1:02:03".
---@param secs number|nil
---@return string
function M.clock(secs)
  if not secs then
    return ""
  end
  secs = math.max(0, math.floor(secs))
  if secs < 60 then
    return ("%ds"):format(secs)
  elseif secs < 3600 then
    return ("%d:%02d"):format(math.floor(secs / 60), secs % 60)
  end
  return ("%d:%02d:%02d"):format(math.floor(secs / 3600), math.floor(secs % 3600 / 60), secs % 60)
end

--- Day of the week of `d`: 1 = Monday … 7 = Sunday.
---@param d gg.ui.Date
---@return integer
function M.weekday(d)
  -- 1970-01-01 was a Thursday (4)
  return (days_from_civil(d.year, d.month, d.day) + 3) % 7 + 1
end

--- `d` plus `n` days.
---@param d gg.ui.Date
---@param n integer
---@return gg.ui.Date
function M.add_days(d, n)
  local y, m, day = civil_from_days(days_from_civil(d.year, d.month, d.day) + n)
  return { year = y, month = m, day = day }
end

--- Whole days from `from` to `to`, by the calendar (no time zones).
---@param from gg.ui.Date
---@param to gg.ui.Date
---@return integer
function M.diff_days(from, to)
  return days_from_civil(to.year, to.month, to.day) - days_from_civil(from.year, from.month, from.day)
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
