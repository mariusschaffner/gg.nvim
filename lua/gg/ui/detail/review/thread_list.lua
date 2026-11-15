--- The threads pane of the review: every thread and pending comment, by
--- file. Pure.
---
---   http.lua
---     41 ● should this back off on 429 only?
---     57 ◷ rename this
---   retry.lua
---   file ✓ why a new module?
---
--- `●` an unresolved thread, `✓` a resolved one, `◷` a pending comment (or
--- a thread with a pending reply), `•` a comment that cannot be resolved.
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")
local text = require("gg.ui.lib.text")
local threads = require("gg.ui.detail.review.threads")

local M = {}

M.LINE_WIDTH = 4

---@class gg.ui.ThreadGroup
---@field file gg.ui.ReviewFile
---@field threads gg.ui.ReviewThread[]

--- The threads of every file that has some, in the order of `files`.
---@param files gg.ui.ReviewFile[]
---@param discussions gg.Discussion[]|nil
---@param drafts gg.DraftNote[]|nil
---@param opts? gg.ui.ReviewThreadOpts
---@return gg.ui.ThreadGroup[]
---@return integer count threads in all
function M.groups(files, discussions, drafts, opts)
  local out, count = {}, 0
  for _, f in ipairs(files or {}) do
    local list = threads.for_file(f, discussions, drafts, opts)
    if #list > 0 then
      -- by line; comments on the file first
      for i, t in ipairs(list) do
        t.order = i
      end
      table.sort(list, function(a, b)
        local la = a.file_level and 0 or (a.anchor.new_line or a.anchor.old_line or 0)
        local lb = b.file_level and 0 or (b.anchor.new_line or b.anchor.old_line or 0)
        if la ~= lb then
          return la < lb
        end
        return a.order < b.order
      end)
      table.insert(out, { file = f, threads = list })
      count = count + #list
    end
  end
  return out, count
end

local function state(t)
  local pending = t.pending
  for _, n in ipairs(t.replies) do
    pending = pending or n.pending
  end
  if pending then
    return "◷", "GitlabBadgePending"
  elseif not t.resolvable then
    return "•", "GitlabDetailMuted"
  elseif t.resolved then
    return "✓", "GitlabBadgeResolved"
  end
  return "●", "GitlabBadgeUnresolved"
end

--- Render the pane. Thread rows carry `{ kind = "thread", index, thread }`
--- (`index` of the file), file rows `{ kind = "file", index }`.
---@param input { width: integer, status: "loading"|"ready"|"error", groups?: gg.ui.ThreadGroup[] }
---@return gg.ui.Doc
function M.render(input)
  local d = doc.new()
  if input.status ~= "ready" then
    d:text(input.status == "loading" and " Loading…" or "", "GitlabDetailMuted")
    return d
  end
  local groups = input.groups or {}
  if #groups == 0 then
    d:text(" No threads.", "GitlabDetailMuted")
    return d
  end
  local width = math.max(16, input.width)
  for _, g in ipairs(groups) do
    local name = g.file.path:match("[^/]+$") or g.file.path
    d:line(line.new():add(" "):add(text.truncate(name, width - 2), "GitlabDetailValue"), { kind = "file", index = g.file.index })
    for _, t in ipairs(g.threads) do
      local l = line.new():add(" ")
      local n = not t.file_level and (t.anchor.new_line or t.anchor.old_line) or nil
      local at = n and tostring(n) or "file"
      l:add(string.rep(" ", math.max(0, M.LINE_WIDTH - #at)) .. at, "GitlabDiffLineNr"):add(" ")
      local icon, hl = state(t)
      l:add(icon, hl):add(" ")
      local first = text.clean(((t.root.body or ""):match("^%s*([^\n]*)")) or "")
      local muted = t.resolved or t.outdated
      l:add(text.truncate(first, math.max(4, width - l.cells - 1)), muted and "GitlabDetailMuted" or "GitlabDetailValue")
      d:line(l, { kind = "thread", index = g.file.index, thread = t.id })
    end
  end
  return d
end

return M
