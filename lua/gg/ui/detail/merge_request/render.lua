--- The merge request detail view's header, sidebar and description. Pure.
local avatar = require("gg.ui.lib.avatar")
local chip = require("gg.ui.lib.chip")
local date = require("gg.ui.lib.date")
local doc = require("gg.ui.lib.doc")
local header = require("gg.ui.detail.header")
local line = require("gg.ui.lib.line")
local markdown = require("gg.ui.lib.markdown")
local readiness = require("gg.ui.detail.merge_request.readiness")
local sidebar = require("gg.ui.detail.sidebar")
local strip = require("gg.ui.lib.strip")
local text = require("gg.ui.lib.text")

local M = {}

M.BRANCH = "⎇"

--- The state pill: Open, Draft, Merged or Closed.
---@param mr gg.MergeRequest
---@return { [1]: string, [2]: string }
function M.pill(mr)
  if mr.state == "merged" then
    return chip.pill("●", "Merged", "GitlabPillMerged")
  elseif mr.state == "closed" then
    return chip.pill("●", "Closed", "GitlabPillDeclined")
  elseif mr.draft then
    return chip.pill("●", "Draft", "GitlabPillDraft")
  end
  return chip.pill("●", "Open", "GitlabPillOpened")
end

---@class gg.ui.MrDetailData
---@field mr gg.MergeRequest
---@field project string
---@field checks gg.ui.Loadable gg.MergeChecks
---@field reviewers gg.ui.Loadable gg.Reviewer[]
---@field refs gg.ui.ClosingRef[]
---@field issues table<string, gg.Issue|false> by ref key; false = not found, absent = loading
---@field now integer
---@field chip_hl? gg.ui.ChipHl
---@field user_colors? table<string, string>
---@field me? string
---@field pipeline_key? string

--- The readiness block for the header (or a loading / error line).
---@param data gg.ui.MrDetailData
---@param width integer
---@param narrow boolean one line instead of the strip
---@return gg.ui.Doc
function M.readiness(data, width, narrow)
  local d = doc.new()
  if data.checks.status == "loading" or data.reviewers.status == "loading" then
    d:text(" Loading merge status…", "GitlabDetailMuted")
    return d
  elseif data.checks.status == "error" then
    d:text(" " .. text.truncate("Merge status unavailable: " .. (data.checks.error or ""), width - 2), "GitlabDetailError")
    return d
  end
  local r = readiness.compute({
    mr = data.mr,
    checks = data.checks.value,
    reviewers = data.reviewers.status == "ready" and data.reviewers.value or {},
  })
  local nodes = readiness.nodes(r, { pipeline_key = data.pipeline_key })
  if narrow then
    local tail = r.merge.state == "blocked" and (r.merge.reason and (r.merge.reason .. " · blocked") or "blocked") or nil
    local l = line.new():add(" ")
    l:segments(strip.compact(nodes, tail), width - 2)
    d:line(l)
    return d
  end
  return strip.render(nodes, width - 2)
end

--- The header: the body and the border title.
---@param data gg.ui.MrDetailData
---@param width integer
---@param narrow boolean
---@return gg.ui.Doc body
---@return gg.ui.Chunk[] title
function M.header(data, width, narrow)
  local mr = data.mr
  local body = header.build({
    width = width,
    pill = M.pill(mr),
    title = mr.title or "",
    ref = "!" .. tostring(mr.iid),
    strip = narrow and M.strip(data) or nil,
    extra = M.readiness(data, width, narrow),
  })
  local meta = {}
  if mr.author then
    table.insert(meta, { "opened by " .. (mr.author.name or mr.author.username) })
  end
  if mr.updated_at then
    local age = date.age(mr.updated_at, data.now)
    table.insert(meta, { (#meta > 0 and " · " or "") .. "updated " .. (age == "now" and "just now" or (age .. " ago")) })
  end
  local title = header.border_title(width, header.crumb(mr.project or data.project, "merge requests"), "!" .. tostring(mr.iid), meta)
  return body, title
end

--- The one-line summary for windows without a sidebar.
---@param data gg.ui.MrDetailData
---@return string
function M.strip(data)
  local mr = data.mr
  local parts = { ("%s → %s"):format(mr.source_branch or "?", mr.target_branch or "?") }
  local a = mr.assignees and mr.assignees[1]
  table.insert(parts, a and ("@" .. a.username) or "unassigned")
  local reviewers = mr.reviewers or {}
  if #reviewers > 0 then
    table.insert(parts, "review: " .. table.concat(vim.tbl_map(function(u)
      return "@" .. u.username
    end, reviewers), " "))
  end
  if mr.milestone then
    table.insert(parts, "◆ " .. mr.milestone.title)
  end
  return table.concat(parts, " · ")
end

local REVIEW = {
  approved = { "✓ approved", "GitlabStripDone" },
  requested_changes = { "✗ changes", "GitlabStripFailed" },
  reviewed = { "● reviewed", "GitlabDetailMuted" },
}

--- The sidebar.
---@param data gg.ui.MrDetailData
---@param width integer
---@return gg.ui.Doc
function M.sidebar(data, width)
  local mr = data.mr
  local inner = sidebar.inner(width)
  local opts = { overrides = data.user_colors, me = data.me }
  local assignees = vim.tbl_map(function(u)
    return avatar.segments(u, opts)
  end, mr.assignees or {})

  local reviewers = {}
  if data.reviewers.status == "ready" then
    for _, r in ipairs(data.reviewers.value) do
      if r.role ~= "participant" then
        local state = r.approved and REVIEW.approved or REVIEW[r.review_state or ""] or { "◷ pending", "GitlabStripPending" }
        local who = avatar.segments(r.user, opts)
        table.insert(reviewers, sidebar.spread({ who[1], { " " .. text.truncate(r.user.username or "?", math.max(1, inner - 16)), "GitlabDetailValue" } }, { state }, inner))
      end
    end
  elseif data.reviewers.status == "error" then
    reviewers = { { { text.truncate(data.reviewers.error or "failed", inner), "GitlabDetailError" } } }
  else
    for _, u in ipairs(mr.reviewers or {}) do
      table.insert(reviewers, avatar.segments(u, opts))
    end
  end

  local on_merge = {}
  local delete = mr.force_remove_source_branch or mr.should_remove_source_branch
  table.insert(on_merge, {
    { delete and "●" or "○", delete and "GitlabDetailPositive" or "GitlabDetailMuted" },
    { " Delete source branch", delete and "GitlabDetailValue" or "GitlabDetailMuted" },
  })
  for _, r in ipairs(data.refs or {}) do
    table.insert(on_merge, { { "●", "GitlabDetailPositive" }, { " Close " .. r.key, "GitlabDetailValue" } })
  end

  return sidebar.build({
    {
      label = "Branches",
      lines = {
        { { M.BRANCH .. " " .. (mr.source_branch or "?"), "GitlabBranchSource" } },
        { { "↳ ", "GitlabDetailMuted" }, { M.BRANCH .. " " .. (mr.target_branch or "?"), "GitlabBranchTarget" } },
      },
    },
    { label = "Assignee", lines = assignees, empty = "unassigned" },
    { label = "Reviewers", lines = reviewers, empty = "no reviewers" },
    { label = "Labels", lines = chip.wrap(mr.labels or {}, inner, data.chip_hl), empty = "no labels" },
    { label = "Milestone", lines = mr.milestone and { { { "◆ " .. mr.milestone.title, "GitlabMilestoneRef" } } } or {}, empty = "no milestone" },
    { divider = true },
    { label = "On merge", lines = on_merge },
  }, width)
end

-- the first workflow label of an issue
local function wf_label(issue)
  for _, l in ipairs(issue.labels or {}) do
    if tostring(l.name or ""):match("^%s*[Ww][Ff]%s*:") then
      return l
    end
  end
  return nil
end

--- One issue card: "  ● #22  Issue title            WF:Review ".
---@param ref gg.ui.ClosingRef
---@param issue gg.Issue|false|nil false: not found; nil: still loading
---@param width integer
---@param chip_hl? gg.ui.ChipHl
---@return gg.ui.Doc
function M.card(ref, issue, width, chip_hl)
  local d = doc.new()
  local l = line.new():add("  ")
  local dot, dot_hl = "●", "GitlabDetailMuted"
  if issue then
    dot_hl = issue.state == "closed" and "GitlabStateClosed" or "GitlabStateOpened"
  end
  l:add(dot, dot_hl):add(" "):add(ref.key, "GitlabIid"):add("  ")
  local right = issue and wf_label(issue)
  local right_seg = right and chip.label(right, chip_hl) or nil
  local right_w = right_seg and text.width(right_seg[1]) + 1 or 0
  local room = math.max(4, width - l.cells - right_w - 1)
  if issue then
    l:add(text.truncate(text.clean(issue.title), room), "GitlabDetailTitle")
  elseif issue == false then
    l:add("not found", "GitlabDetailMuted")
  else
    l:add("Loading…", "GitlabDetailMuted")
  end
  if right_seg then
    l:pad_to(width - right_w):add(right_seg[1], right_seg[2])
  end
  l:pad_to(width)
  local lnum = d:line(l, { kind = "card", ref = ref, issue = issue or nil })
  d:line_hl(lnum, "GitlabCard")
  return d
end

--- The description: markdown, with the lines that close issues followed by
--- one card per issue.
---@param data gg.ui.MrDetailData
---@param width integer
---@return gg.ui.Doc
function M.description(data, width)
  local by_line = {}
  for _, r in ipairs(data.refs or {}) do
    by_line[r.line] = by_line[r.line] or {}
    table.insert(by_line[r.line], r)
  end
  return markdown.render(data.mr.description, {
    width = width,
    empty = "No description.",
    replace = function(lnum, s)
      local refs = by_line[lnum]
      if not refs then
        return nil
      end
      local d = markdown.render(s, { width = width })
      for _, r in ipairs(refs) do
        d:append(M.card(r, data.issues[r.key], width, data.chip_hl))
      end
      return d
    end,
  })
end

return M
