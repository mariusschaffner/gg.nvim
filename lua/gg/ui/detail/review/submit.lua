--- Submitting a review: the choices and what each one sends. Pure.
local M = {}

---@class gg.ui.ReviewAction
---@field key "show"|"comment"|"approve"|"changes"|"discard"
---@field label string
---@field reviewer_state "reviewed"|"requested_changes"|nil sent with the drafts
---@field approve boolean|nil approve after publishing
---@field verb string|nil the composer's submit label

local function comments(n)
  return ("%d pending comment%s"):format(n, n == 1 and "" or "s")
end

--- The title of the choice: "Submit review · 2 pending comments".
---@param pending integer
---@return string
function M.title(pending)
  return "Submit review · " .. (pending > 0 and comments(pending) or "no pending comments")
end

--- What a review can be submitted as; discarding is offered only with
--- pending comments.
---@param pending integer
---@return gg.ui.ReviewAction[]
function M.actions(pending)
  local out = {
    { key = "comment", label = "Comment · send the review", reviewer_state = "reviewed", verb = "Submit review" },
    { key = "approve", label = "Approve · send the review and approve", approve = true, verb = "Submit & approve" },
    { key = "changes", label = "Request changes · send the review and request changes", reviewer_state = "requested_changes", verb = "Request changes" },
  }
  if pending > 0 then
    table.insert(out, 1, { key = "show", label = "Show · list the " .. comments(pending) })
    table.insert(out, { key = "discard", label = "Discard · delete the " .. comments(pending) })
  end
  return out
end

---@class gg.ui.PendingEntry
---@field text string "path:line  first line of the comment"
---@field path string|nil the file it is on (nil: a general comment)
---@field note string the id of its note in the review ("draft:<id>")

--- One entry per pending comment: where it is and how it starts.
---@param drafts gg.DraftNote[]|nil
---@param discussions gg.Discussion[]|nil to place replies
---@return gg.ui.PendingEntry[]
function M.pending(drafts, discussions)
  local where = {}
  for _, d in ipairs(discussions or {}) do
    for _, n in ipairs(d.notes or {}) do
      if not n.system then
        where[d.id] = n.position or false
        break
      end
    end
  end
  local out = {}
  for _, dr in ipairs(drafts or {}) do
    local p = dr.position
    local reply = false
    if dr.discussion_id then
      p, reply = where[dr.discussion_id] or nil, true
    end
    local at, path = "general", nil
    if p and (p.new_path or p.old_path) then
      local line = p.new_line or p.old_line
      path = p.new_path or p.old_path
      at = path .. (line and (":" .. line) or "")
    end
    local first = (dr.note or ""):match("^%s*([^\n]*)") or ""
    table.insert(out, { text = ("%s%s  %s"):format(reply and "↩ " or "", at, first), path = path, note = "draft:" .. tostring(dr.id) })
  end
  return out
end

return M
