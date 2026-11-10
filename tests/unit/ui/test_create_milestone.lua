-- New milestone: the two date floats, their overlay, validation, submit.
local H = require("tests.helpers")
local P = require("tests.support.create_data")
local X = require("tests.support.detail_data")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = { pre_case = P.pre_case, post_case = P.post_case } })

local MILESTONES = "/api/v4/projects/" .. X.ENC .. "/milestones"

local function rest_milestone()
  return { id = 11, iid = 1, project_id = 7, title = "Sprint 3", description = "Plan.", state = "active", start_date = "2026-11-16", due_date = "2026-11-27", web_url = "https://gitlab.example.com/infra/ops/-/milestones/1" }
end

-- the field overlay is the current window (zindex 200)
local function overlay()
  return vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).zindex == 200
end

T["layout: title, Start and Due side by side, body"] = function()
  local p = P.open("milestone")
  local m = p.group.members
  local function geo(win)
    local c = vim.api.nvim_win_get_config(win)
    return { c.row, c.col, c.width, c.height }
  end
  eq(P.title(m.title.win), " ＋ New milestone ")
  eq(vim.api.nvim_win_get_config(m.title.win).title[1][2], "GitlabCreateMilestone")
  -- 119 wide at column 25: two floats of 58 and 59 outer columns, 2 apart
  eq(geo(m.field_start.win), { 11, 25, 56, 1 })
  eq(geo(m.field_due.win), { 11, 85, 57, 1 })
  eq(geo(m.body.win), { 15, 25, 117, 24 })
  eq(P.title(m.field_start.win), " [gs] Start ")
  eq(P.title(m.field_due.win), " [gd] Due ")
  eq(P.title(m.body.win):find(" Milestone ─", 1, true) ~= nil, true)
  eq(P.lines(m.field_start.buf), { "yyyy-mm-dd" })
  eq(P.virt(m.title.buf), { "title" })
end

T["Tab goes title -> start -> due -> body -> title"] = function()
  local p = P.open("milestone")
  local m = p.group.members
  vim.cmd("stopinsert")
  local seen = {}
  for _ = 1, 4 do
    P.keys("<Tab>")
    table.insert(seen, p.group:name_of(vim.api.nvim_get_current_win()))
  end
  eq(seen, { "field_start", "field_due", "body", "title" })
  eq(vim.wo[m.title.win].winhighlight:find("FloatBorder:GitlabCreateMilestone", 1, true) ~= nil, true)
end

T["gs / gd edit a date in an overlay; both spellings are accepted"] = function()
  local p = P.open("milestone")
  local m = p.group.members
  vim.cmd("stopinsert")
  p:focus("body")
  P.keys("gs")
  H.wait_for(overlay)
  local cfg = vim.api.nvim_win_get_config(0)
  eq({ cfg.row, cfg.col }, { 12, 26 }) -- over the field's text
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "16.11.2026" })
  P.keys("<C-s>")
  eq(P.lines(m.field_start.buf), { "2026-11-16" })
  eq(vim.api.nvim_get_current_win(), m.field_start.win)
  eq(p:dirty(), true)
  -- not a date: the overlay stays and says why
  p:focus("field_due")
  P.keys("<CR>")
  H.wait_for(overlay)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "soon" })
  P.keys("<C-s>")
  eq(overlay(), true)
  eq(P.notes[#P.notes][1], "gg.ui: Due: not a date (use 2026-11-20 or 20.11.2026)")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "2026-11-27" })
  P.keys("<C-s>")
  eq(P.lines(m.field_due.buf), { "2026-11-27" })
  -- an empty value unsets the date
  P.keys("gd")
  H.wait_for(overlay)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
  P.keys("<C-s>")
  eq(P.lines(m.field_due.buf), { "yyyy-mm-dd" })
  eq(p:field("due"), nil)
end

T["a due date before the start date is refused in its float"] = function()
  local p, _, fake = P.open("milestone", { title = "Sprint 3", start_date = "2026-11-20", due_date = "2026-11-10" })
  eq(p:dirty(), false)
  P.keys("<C-s>")
  eq(#fake:requests(), 0)
  eq(P.diagnostics(p, p.group.members.field_due.buf), { "The due date is before the start date" })
  eq(vim.api.nvim_get_current_win(), p.group.members.field_due.win)
  -- a new value clears the error
  p:set_field("due", "2026-11-27")
  eq(P.diagnostics(p, p.group.members.field_due.buf), {})
  eq(p.state, "idle")
end

T["<C-s> creates the milestone with its dates and opens it"] = function()
  local responses = X.milestone_responses()
  table.insert(responses, {
    request = { method = "POST", path = MILESTONES },
    response = { status = 201, body = rest_milestone() },
  })
  local p, s, fake = P.open("milestone", { start_date = "2026-11-16", due_date = "2026-11-27" }, responses)
  local m = p.group.members
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(m.title.buf, 0, -1, false, { "Sprint 3" })
  vim.api.nvim_buf_set_lines(m.body.buf, 0, -1, false, { "Plan." })
  P.keys("<C-s>")
  H.wait_for(function()
    return p.closed and s:depth() == 2 and s:top().group.members.header ~= nil
  end)
  local post
  for _, r in ipairs(fake:requests()) do
    if r.method == "POST" and r.path == MILESTONES then
      post = r.json
    end
  end
  eq(post, { title = "Sprint 3", description = "Plan.", start_date = "2026-11-16", due_date = "2026-11-27" })
  eq(s.screens[1].dirty, { milestone = true, issue = true })
end

T["an API error on a date goes to the date float"] = function()
  local p = P.open("milestone", { title = "x" }, {
    { request = { method = "POST", path = MILESTONES }, response = { status = 400, body = { message = { due_date = { "must be greater than start date" } } } } },
  })
  P.keys("<C-s>")
  H.wait_for(function()
    return p.state == "error"
  end)
  eq(P.diagnostics(p, p.group.members.field_due.buf), { "must be greater than start date" })
end

return T
