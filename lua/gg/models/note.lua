--- Notes (comments, system notes) and discussions (threads). Pure.
---
--- Rules:
---   * resolution data (`resolvable`, `resolved`, `resolved_by`, `resolved_at`)
---     belongs to the thread: it is set on the discussion and its root note,
---     never on replies.
---   * a diff note whose `position` is gone but has an `original_position`
---     is outdated; it keeps the original position.
local gid = require("gg.models.gid")
local user = require("gg.models.user")
local util = require("gg.models.util")

local M = {}

---@class gg.DiffPosition
---@field base_sha string|nil
---@field start_sha string|nil
---@field head_sha string|nil
---@field old_path string|nil
---@field new_path string|nil
---@field old_line integer|nil
---@field new_line integer|nil
---@field position_type string "text" | "image" | "file"
---@field line_range table|nil REST line_range, as sent by GitLab

---@class gg.Reaction
---@field name string emoji name, e.g. "thumbsup"
---@field username string|nil

---@class gg.Note
---@field id integer
---@field discussion_id string|nil
---@field body string
---@field author gg.User|nil
---@field system boolean
---@field system_note_icon_name string|nil
---@field system_action string|nil system note metadata action (e.g. "assignee", "commit")
---@field internal boolean|nil
---@field created_at string
---@field updated_at string|nil
---@field resolvable boolean|nil only on a thread's root note
---@field resolved boolean|nil only on a thread's root note
---@field resolved_by gg.User|nil only on a thread's root note
---@field resolved_at string|nil only on a thread's root note
---@field position gg.DiffPosition|nil for diff notes (the original position when outdated)
---@field outdated boolean|nil
---@field reactions gg.Reaction[]|nil
---@field url string|nil

---@class gg.Discussion
---@field id string
---@field individual_note boolean|nil a plain comment, not a thread
---@field resolvable boolean
---@field resolved boolean
---@field resolved_by gg.User|nil
---@field resolved_at string|nil
---@field notes gg.Note[]
---@field truncated gg.Truncated|nil

local function position_rest(p)
  p = util.value(p)
  if type(p) ~= "table" then
    return nil
  end
  return {
    base_sha = util.value(p.base_sha),
    start_sha = util.value(p.start_sha),
    head_sha = util.value(p.head_sha),
    old_path = util.value(p.old_path),
    new_path = util.value(p.new_path),
    old_line = tonumber(util.value(p.old_line)),
    new_line = tonumber(util.value(p.new_line)),
    position_type = util.value(p.position_type) or "text",
    line_range = util.value(p.line_range),
  }
end

local function position_graphql(p)
  p = util.value(p)
  if type(p) ~= "table" then
    return nil
  end
  local refs = util.value(p.diffRefs) or {}
  return {
    base_sha = util.value(refs.baseSha),
    start_sha = util.value(refs.startSha),
    head_sha = util.value(refs.headSha),
    old_path = util.value(p.oldPath),
    new_path = util.value(p.newPath) or util.value(p.filePath),
    old_line = tonumber(util.value(p.oldLine)),
    new_line = tonumber(util.value(p.newLine)),
    position_type = util.value(p.positionType) or "text",
  }
end

--- Map a REST note (from discussions or the notes API).
---@param raw table|nil
---@param ctx? { origin?: string, discussion_id?: string }
---@return gg.Note|nil
function M.note_from_rest(raw, ctx)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  ctx = ctx or {}
  local pos = position_rest(raw.position)
  local original = position_rest(raw.original_position)
  local outdated = pos == nil and original ~= nil
  return {
    id = tonumber(util.value(raw.id)),
    discussion_id = ctx.discussion_id,
    body = util.value(raw.body) or "",
    author = user.from_rest(raw.author, ctx),
    system = util.value(raw.system) == true,
    internal = util.value(raw.internal) or util.value(raw.confidential),
    created_at = util.value(raw.created_at),
    updated_at = util.value(raw.updated_at),
    resolvable = util.value(raw.resolvable),
    resolved = util.value(raw.resolved),
    resolved_by = user.from_rest(raw.resolved_by, ctx),
    resolved_at = util.value(raw.resolved_at),
    position = pos or original,
    outdated = outdated or nil,
  }
end

--- Map a GraphQL Note node (NoteFields).
---@param node table|nil
---@param ctx? { origin?: string }
---@return gg.Note|nil
function M.note_from_graphql(node, ctx)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  local discussion = util.value(node.discussion)
  local meta = util.value(node.systemNoteMetadata)
  local reactions
  if util.value(node.awardEmoji) ~= nil then
    reactions = util.map(util.nodes(node.awardEmoji), function(a)
      local u = util.value(a.user)
      return { name = util.value(a.name), username = u and util.value(u.username) or nil }
    end)
  end
  return {
    id = gid.tail(util.value(node.id)),
    discussion_id = discussion and gid.tail(util.value(discussion.id)) or nil,
    body = util.value(node.body) or "",
    author = user.from_graphql(node.author, ctx),
    system = util.value(node.system) == true,
    system_note_icon_name = util.value(node.systemNoteIconName),
    system_action = meta and util.value(meta.action) or nil,
    internal = util.value(node.internal),
    created_at = util.value(node.createdAt),
    updated_at = util.value(node.updatedAt),
    resolvable = util.value(node.resolvable),
    resolved = util.value(node.resolved),
    position = position_graphql(node.position),
    reactions = reactions,
    url = util.value(node.url),
  }
end

-- keep resolution data on the root note only
local function root_only(notes)
  for i, n in ipairs(notes) do
    if i > 1 then
      n.resolvable, n.resolved, n.resolved_by, n.resolved_at = nil, nil, nil, nil
    end
  end
  return notes
end

--- Map a REST discussion (`{ id, individual_note, notes }`). A missing
--- `notes` array gives a discussion without notes (nil-safe).
---@param raw table|nil
---@param ctx? { origin?: string }
---@return gg.Discussion|nil
function M.discussion_from_rest(raw, ctx)
  raw = util.value(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local id = util.value(raw.id)
  local notes = util.map(raw.notes, function(n)
    return M.note_from_rest(n, { origin = ctx and ctx.origin, discussion_id = id })
  end)
  local root = notes[1] or {}
  if root.resolved ~= true then
    root.resolved_by, root.resolved_at = nil, nil
  end
  local d = {
    id = id,
    individual_note = util.value(raw.individual_note),
    resolvable = root.resolvable == true,
    resolved = root.resolved == true,
    resolved_by = root.resolved_by,
    resolved_at = root.resolved_at,
    notes = root_only(notes),
  }
  return d
end

--- Map a GraphQL Discussion node.
---@param node table|nil
---@param ctx? { origin?: string }
---@return gg.Discussion|nil
function M.discussion_from_graphql(node, ctx)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  local id = gid.tail(util.value(node.id))
  local notes = util.map(util.nodes(node.notes), function(n)
    local note = M.note_from_graphql(n, ctx)
    note.discussion_id = note.discussion_id or id
    return note
  end)
  local resolved = util.value(node.resolved) == true
  local d = {
    id = id,
    resolvable = util.value(node.resolvable) == true,
    resolved = resolved,
    resolved_by = resolved and user.from_graphql(node.resolvedBy, ctx) or nil,
    resolved_at = resolved and util.value(node.resolvedAt) or nil,
    notes = root_only(notes),
    truncated = util.has_more(node.notes) and { notes = true } or nil,
  }
  if notes[1] then
    notes[1].resolved_by, notes[1].resolved_at = d.resolved_by, d.resolved_at
  end
  return d
end

return M
