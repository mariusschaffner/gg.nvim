--- The Commits tab: commits grouped by day, each with its conventional
--- commit type, scope, time, author and short SHA; the subject on the line
--- below along the graph. Pure.
---
---   ──── 21.10.2026 ─────────────────────────────────────────────
---    ○  feat   ui                          14:02  Ann Example  abcd1234
---    │   add the detail views
---    ◇  merge                              13:10  Ann Example  ef01ab23
---    │   feature-x → main
local date = require("gg.ui.lib.date")
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")
local text = require("gg.ui.lib.text")
local user_hl = require("gg.ui.lib.user_hl")

local M = {}

M.TYPES = {
  feat = { "GitlabChipFeat", "GitlabCommitFeat" },
  fix = { "GitlabChipFix", "GitlabCommitFix" },
  test = { "GitlabChipTest", "GitlabCommitTest" },
  testing = { "GitlabChipTest", "GitlabCommitTest" },
  merge = { "GitlabChipMerge", "GitlabCommitMerge" },
  docs = { "GitlabChipDocs", "GitlabCommitDocs" },
  refactor = { "GitlabChipRefactor", "GitlabCommitRefactor" },
  perf = { "GitlabChipRefactor", "GitlabCommitRefactor" },
  revert = { "GitlabChipRevert", "GitlabCommitRevert" },
}
local OTHER = { "GitlabChipOther", "GitlabCommitOther" }

---@class gg.ui.ParsedCommit
---@field type string|nil "feat", "merge", … (nil: not conventional)
---@field scope string|nil
---@field breaking boolean
---@field subject string

--- Parse a commit title: `type(scope)!: subject`; merge commits become
--- "source → target".
---@param title string|nil
---@return gg.ui.ParsedCommit
function M.parse(title)
  title = text.clean(title or "")
  local src, dst = title:match("^Merge branch '([^']+)' into '([^']+)'")
  if src then
    return { type = "merge", subject = src .. " → " .. dst, breaking = false }
  end
  src = title:match("^Merge branch '([^']+)'")
  if src then
    return { type = "merge", subject = src, breaking = false }
  end
  if title:match("^Merge ") then
    return { type = "merge", subject = title:gsub("^Merge%s+", ""), breaking = false }
  end
  local t, scope, bang, subject = title:match("^(%a+)%(([^%)]*)%)(!?):%s*(.*)$")
  if not t then
    t, bang, subject = title:match("^(%a+)(!?):%s*(.*)$")
  end
  if t then
    return { type = t:lower(), scope = scope ~= "" and scope or nil, breaking = bang == "!", subject = subject }
  end
  return { subject = title, breaking = false }
end

--- "3 feat · 2 fix · 1 merge": commit types, most frequent first.
---@param commits gg.Commit[]
---@return string
function M.tally(commits)
  local counts, order = {}, {}
  for _, c in ipairs(commits) do
    local t = M.parse(c.title).type or "other"
    if not counts[t] then
      counts[t] = 0
      table.insert(order, t)
    end
    counts[t] = counts[t] + 1
  end
  table.sort(order, function(a, b)
    if counts[a] ~= counts[b] then
      return counts[a] > counts[b]
    end
    return a < b
  end)
  return table.concat(vim.tbl_map(function(t)
    return ("%d %s"):format(counts[t], t)
  end, order), " · ")
end

---@class gg.ui.CommitsInput
---@field width integer
---@field status "loading"|"ready"|"error"
---@field commits? gg.Commit[] newest first
---@field error? string
---@field today gg.ui.Date
---@field utc_offset? integer
---@field user_colors? table<string, string>

--- Render the tab.
---@param input gg.ui.CommitsInput
---@return gg.ui.Doc
function M.render(input)
  local d = doc.new()
  if input.status == "loading" then
    d:text(" Loading commits…", "GitlabDetailMuted")
    return d
  elseif input.status == "error" then
    d:text(" " .. (input.error or "Failed to load the commits"), "GitlabDetailError")
    return d
  end
  local commits = input.commits or {}
  if #commits == 0 then
    d:text(" No commits.", "GitlabDetailMuted")
    return d
  end
  local width = math.max(40, input.width)
  local last_day
  for _, c in ipairs(commits) do
    local at = c.authored_date or c.committed_date
    local day = date.local_day(at, input.utc_offset)
    if day and not date.same_day(day, last_day) then
      if last_day then
        d:blank()
      end
      local label = " " .. date.day_label(day, input.today) .. " "
      d:line(line.new():add("────", "GitlabTimelineRule"):add(label, "GitlabTimelineDay"):add(text.rep("─", width - 4 - text.width(label)), "GitlabTimelineRule"))
      last_day = day
    end
    local p = M.parse(c.title)
    local hls = M.TYPES[p.type or ""] or OTHER
    local l = line.new():add(" "):add(p.type == "merge" and "◇" or "○", hls[2]):add("  ")
    if p.type then
      l:add(" " .. p.type .. (p.breaking and "!" or "") .. " ", hls[1]):add(" ")
    end
    if p.scope then
      l:add(p.scope, "GitlabDetailMuted")
    end
    local author = c.author and c.author.username or nil
    local who = c.author and (c.author.name or c.author.username) or c.author_name or "?"
    local right = {
      { date.hhmm(at, input.utc_offset), "GitlabTimelineTime" },
      { "  ", nil },
      { text.truncate(who, 18), author and user_hl.group(author, input.user_colors) or "GitlabDetailValue" },
      { "  ", nil },
      { c.short_sha or (c.sha or ""):sub(1, 8), "GitlabSha" },
    }
    local rw = 0
    for _, s in ipairs(right) do
      rw = rw + text.width(s[1])
    end
    l:pad_to(math.max(l.cells + 1, width - rw))
    for _, s in ipairs(right) do
      l:add(s[1], s[2])
    end
    d:line(l, { kind = "commit", sha = c.sha })
    d:line(
      line.new():add(" "):add("│", "GitlabTimelineGuide"):add("   "):add(text.truncate(p.subject, width - 6), p.type == "merge" and "GitlabDetailMuted" or "GitlabDetailValue"),
      { kind = "commit", sha = c.sha }
    )
  end
  return d
end

return M
