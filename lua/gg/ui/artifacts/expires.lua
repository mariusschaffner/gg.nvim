--- The Expires cell of an artifact row. Pure.
---
---   kept      no expiry date (kept forever)          GitlabArtifactKept
---   today     less than a day left                   GitlabArtifactExpiring
---   in 1d/2d  at most two days left                  GitlabArtifactExpiring
---   in Nd     more                                   Comment
---   expired   GitLab says so, or the date has passed GitlabArtifactExpired
local date = require("gg.ui.lib.date")

local M = {}

M.SOON_DAYS = 2

-- whole days left (nil when kept or unknown), or false when expired
local function days_left(a, now)
  if a.expired then
    return false
  end
  if not a.expire_at then
    return nil
  end
  local t = date.parse_time(a.expire_at)
  if not t then
    return nil
  end
  local left = t - now
  if left <= 0 then
    return false
  end
  return math.floor(left / 86400)
end

--- True when the artifact has no expiry date.
---@param a gg.JobArtifact
---@return boolean
function M.kept(a)
  return not a.expired and a.expire_at == nil
end

--- True when the artifact has expired.
---@param a gg.JobArtifact
---@param now integer epoch seconds
---@return boolean
function M.expired(a, now)
  return days_left(a, now) == false
end

--- True when the artifact expires within SOON_DAYS days.
---@param a gg.JobArtifact
---@param now integer epoch seconds
---@return boolean
function M.expiring(a, now)
  local d = days_left(a, now)
  return type(d) == "number" and d <= M.SOON_DAYS
end

--- The cell text and highlight.
---@param a gg.JobArtifact
---@param now integer epoch seconds
---@return string text
---@return string|nil hl
function M.cell(a, now)
  local d = days_left(a, now)
  if d == false then
    return "expired", "GitlabArtifactExpired"
  end
  if d == nil then
    if a.expire_at == nil then
      return "kept", "GitlabArtifactKept"
    end
    return "", nil
  end
  if d == 0 then
    return "today", "GitlabArtifactExpiring"
  end
  return ("in %dd"):format(d), d <= M.SOON_DAYS and "GitlabArtifactExpiring" or "Comment"
end

return M
