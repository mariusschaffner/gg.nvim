--- Reviews: reviewers with their state, and draft notes. Pure.
local note = require("gg.models.note")
local user = require("gg.models.user")
local util = require("gg.models.util")

local M = {}

---@class gg.Reviewer
---@field user gg.User
---@field role "reviewer"|"participant" participant = approved without being a reviewer
---@field review_state string|nil "unreviewed", "reviewed", "requested_changes", "approved", "unapproved", "review_started"
---@field approved boolean

---@class gg.DraftNote
---@field id integer
---@field note string
---@field author_id integer|nil
---@field discussion_id string|nil set for replies
---@field resolve_discussion boolean
---@field commit_id string|nil
---@field line_code string|nil
---@field position gg.DiffPosition|nil only for diff comments (empty positions are nil)

--- Build the reviewer list from a GraphQL MergeRequest node selected by
--- MrReviewers. Approvers who are not reviewers come back as participants
--- (atlas's rule).
---@param node table
---@param ctx? { origin?: string }
---@return gg.Reviewer[]
---@return gg.Truncated|nil
function M.reviewers_from_graphql(node, ctx)
  node = util.value(node) or {}
  local out, seen = {}, {}
  for _, r in ipairs(util.nodes(node.reviewers)) do
    local u = user.from_graphql(r, ctx)
    local i = util.value(r.mergeRequestInteraction) or {}
    seen[u.id] = true
    table.insert(out, {
      user = u,
      role = "reviewer",
      review_state = util.lower(i.reviewState),
      approved = util.value(i.approved) == true,
    })
  end
  for _, a in ipairs(util.nodes(node.approvedBy)) do
    local u = user.from_graphql(a, ctx)
    if u and not seen[u.id] then
      table.insert(out, { user = u, role = "participant", review_state = "approved", approved = true })
    end
  end
  local truncated
  if util.has_more(node.reviewers) or util.has_more(node.approvedBy) then
    truncated = { reviewers = true }
  end
  return out, truncated
end

--- Map a REST draft note.
---@param raw table|nil
---@return gg.DraftNote|nil
function M.draft_from_rest(raw)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local pos
  local p = util.value(raw.position)
  -- GitLab returns an all-null position for general (non-diff) drafts
  if type(p) == "table" and (util.value(p.new_path) or util.value(p.old_path)) then
    pos = note.note_from_rest({ position = p }).position
  end
  return {
    id = tonumber(util.value(raw.id)),
    note = util.value(raw.note) or "",
    author_id = tonumber(util.value(raw.author_id)),
    discussion_id = util.value(raw.discussion_id),
    resolve_discussion = util.value(raw.resolve_discussion) == true,
    commit_id = util.value(raw.commit_id),
    line_code = util.value(raw.line_code),
    position = pos,
  }
end

return M
