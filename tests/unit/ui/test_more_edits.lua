-- Editing milestones and merge requests, and the A actions menus.
local H = require("tests.helpers")
local X = require("tests.support.detail_data")
local config = require("gg.ui.config")
local date = require("gg.ui.lib.date")
local detail = require("gg.ui.detail")
local edits = require("gg.ui.detail.edits")
local stack = require("gg.ui.components.stack")
local eq = MiniTest.expect.equality

local s
local saved = {}
local notes

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { columns = vim.o.columns, lines = vim.o.lines, notify = vim.notify, utc = date.utc_offset, select = vim.ui.select, input = vim.ui.input }
      vim.o.columns, vim.o.lines = 170, 50
      date.utc_offset = function()
        return 0
      end
      notes = {}
      vim.notify = function(msg, level)
        table.insert(notes, { msg, level })
      end
    end,
    post_case = function()
      vim.cmd("stopinsert")
      if s and not s:is_closed() then
        s:close()
      end
      s = nil
      vim.notify, vim.ui.select, vim.ui.input = saved.notify, saved.select, saved.input
      date.utc_offset = saved.utc
      vim.o.columns, vim.o.lines = saved.columns, saved.lines
      config.setup()
      H.reset()
    end,
  },
})

local function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "x", false)
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- the last write (PUT / POST) the fake saw
local function written(fake)
  local reqs = fake:requests()
  for i = #reqs, 1, -1 do
    local r = reqs[i]
    if r.method == "PUT" or (r.method == "POST" and r.path and not r.path:find("graphql", 1, true)) then
      return reqs[i]
    end
  end
end

local function last_note()
  return notes[#notes] and notes[#notes][1]
end

local function overlay_set(text)
  H.wait_for(function()
    return vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).zindex == 200
  end)
  vim.cmd("stopinsert")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { text })
  return win
end

-- pick menu entries by label; answer confirmations with `answer`
local function choose(label, answer)
  local offered
  vim.ui.select = function(items, opts, cb)
    offered = vim.tbl_map(opts.format_item, items)
    for _, it in ipairs(items) do
      if opts.format_item(it) == label then
        return cb(it)
      end
    end
    cb(nil)
  end
  vim.ui.input = function(_, cb)
    cb(answer or "y")
  end
  return function()
    return offered
  end
end

local function ctx()
  return {
    stack = s,
    cfg = config.get(),
    host = X.HOST,
    project = X.PROJECT,
    today = X.TODAY,
    now = function()
      return date.parse_time(X.NOW)
    end,
  }
end

-- Milestone ------------------------------------------------------------------

local function open_milestone(extra)
  local fake = H.fake()
  fake:add(X.milestone_responses())
  fake:add(extra or {})
  s = stack.new()
  detail.milestone(ctx(), { id = 11, title = "2026.11 Patch cycle" })
  local g = s:top().group
  H.wait_for(function()
    return lines(g.members.header.buf)[2]:find("Patch cycle", 1, true) ~= nil and #lines(g.members.header.buf) == 7
  end)
  return g, fake
end

T["milestone: gt, gd over the strip, A close; hints in the header border"] = function()
  local g, fake = open_milestone({
    X.milestone_put({ title = "2026.11 Patches" }, { title = "2026.11 Patches" }),
    X.milestone_put({ due_date = "2026-11-27" }, { title = "2026.11 Patches", due_date = "2026-11-27" }),
    X.milestone_put({ state_event = "close" }, { title = "2026.11 Patches", due_date = "2026-11-27", state = "closed" }),
  })
  local hfoot = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(g.members.header.win).footer))
  eq(hfoot, " [gs] Start • [gd] Due ")
  keys("gt")
  overlay_set("2026.11 Patches")
  keys("<C-s>")
  H.wait_for(function()
    return lines(g.members.header.buf)[2]:find("2026.11 Patches", 1, true) ~= nil
  end)
  eq(fake:last().json, { title = "2026.11 Patches" })
  -- the due date overlay sits on the date label of the strip
  keys("gd")
  local ow = overlay_set("2026-11-27")
  local pos = vim.api.nvim_win_get_config(ow)
  local hdr = vim.api.nvim_win_get_position(g.members.header.win)
  eq(pos.row, hdr[1] + 1 + 3) -- border + blank + title + blank: the tick line
  keys("<C-s>")
  H.wait_for(function()
    return vim.endswith(lines(g.members.header.buf)[4], "27.11.│")
  end)
  eq(fake:last().json.due_date, "2026-11-27")
  -- an empty title is refused
  keys("gt")
  overlay_set("")
  keys("<C-s>")
  eq(last_note(), "gg.ui: Title cannot be empty")
  keys("<Esc>")
  -- A: close
  local offered = choose("Close milestone")
  keys("A")
  eq(offered(), { "Close milestone" })
  H.wait_for(function()
    return lines(g.members.header.buf)[2]:find("Closed", 1, true) ~= nil
  end)
  eq(fake:last().json, { state_event = "close" })
  eq(last_note(), "gg.ui: Milestone closed")
end

T["milestone: description in place"] = function()
  local g, fake = open_milestone({
    X.milestone_get(),
    X.milestone_put({ description = "Only hosts now." }, { description = "Only hosts now." }),
  })
  local win = g.members.content.win
  local tab_buf = vim.api.nvim_win_get_buf(win)
  keys("i")
  H.wait_for(function()
    return vim.api.nvim_win_get_buf(win) ~= tab_buf
  end)
  vim.cmd("stopinsert")
  eq(lines(vim.api.nvim_win_get_buf(win))[1], "Patch everything.")
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { "Only hosts now." })
  keys("<C-s>")
  H.wait_for(function()
    return vim.api.nvim_win_get_buf(win) == tab_buf and lines(tab_buf)[2] == " Only hosts now."
  end)
  eq(fake:last().json, { description = "Only hosts now." })
end

-- Merge request ----------------------------------------------------------------

local function open_mr(extra)
  local fake = H.fake()
  fake:add(X.open_mr_responses())
  fake:add({ X.members(), X.labels_list(), X.milestones_list() })
  fake:add(extra or {})
  s = stack.new()
  detail.merge_request(ctx(), { iid = X.MR_IID })
  local g = s:top().group
  H.wait_for(function()
    local c = lines(g.members.content.buf)
    local side = table.concat(lines(g.members.sidebar.buf), "\n")
    return #c > 4 and c[5]:find("#214", 1, true) ~= nil and side:find("approved", 1, true) ~= nil
  end)
  return g, fake
end

T["merge request: field keys in the sidebar; gr, gB, gb"] = function()
  local g, fake = open_mr({
    X.mr_write("PUT", "", { reviewer_ids = { 2, 3 } }, { reviewers = { X.rest_user(2), X.rest_user(3) } }),
    X.mr_write("PUT", "", { target_branch = "release" }, { target_branch = "release" }),
    { request = { method = "GET", path = ("/api/v4/projects/%s/repository/branches"):format(X.ENC) }, response = { body = {} }, ["repeat"] = true },
    X.mr_write("PUT", "", { remove_source_branch = true }, { should_remove_source_branch = true }),
  })
  local side = table.concat(lines(g.members.sidebar.buf), "\n")
  for _, k in ipairs({ "[gB]", "[ga]", "[gr]", "[gl]", "[gM]", "[gb]" }) do
    eq(side:find(k, 1, true) ~= nil, true)
  end
  local foot = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(g.members.content.win).footer))
  eq(foot, " [i] Edit ")
  -- reviewers: the requested ones are seeded
  keys("gr")
  local ow = overlay_set("user-2, user-3")
  keys("<C-s>")
  H.wait_for(function()
    local w = written(fake)
    return w and w.json and w.json.reviewer_ids ~= nil
  end)
  eq(written(fake).json.reviewer_ids, { 2, 3 })
  H.wait_for(function()
    return not vim.api.nvim_win_is_valid(ow)
  end)
  -- target branch
  keys("gB")
  overlay_set("release")
  keys("<C-s>")
  H.wait_for(function()
    return table.concat(lines(g.members.sidebar.buf), "\n"):find("⎇ release", 1, true) ~= nil
  end)
  -- delete the source branch: off since the last update, so on
  eq(table.concat(lines(g.members.sidebar.buf), "\n"):find("○ Delete source branch", 1, true) ~= nil, true)
  keys("gb")
  H.wait_for(function()
    return last_note() == "gg.ui: The source branch will be deleted on merge"
  end)
  eq(written(fake).json, { remove_source_branch = true })
  eq(table.concat(lines(g.members.sidebar.buf), "\n"):find("● Delete source branch", 1, true) ~= nil, true)
end

T["merge request: A offers what applies; merge asks first"] = function()
  local g, fake = open_mr({
    X.mr_write("PUT", "/merge", { squash = true, should_remove_source_branch = true }, { state = "merged" }),
  })
  -- user-1 (you) has approved in the fixture: revoke instead of approve
  local offered = choose("Merge (squash), delete the source branch", "n")
  keys("A")
  eq(offered(), { "Revoke approval", "Merge (squash), delete the source branch", "Mark as draft", "Close" })
  H.flush(30)
  eq(written(fake), nil) -- answered "n": nothing sent
  choose("Merge (squash), delete the source branch", "y")
  keys("A")
  H.wait_for(function()
    return lines(g.members.header.buf)[2]:find("Merged", 1, true) ~= nil
  end)
  eq(written(fake).json, { squash = true, should_remove_source_branch = true })
  eq(last_note(), "gg.ui: Merged")
end

T["merge request: approve and errors are reported"] = function()
  local fake = H.fake()
  local out = X.open_mr_responses()
  -- someone else approved: you may approve
  local rev = out[3].response.body.data.project.mergeRequest
  rev.approvedBy.nodes = { rev.approvedBy.nodes[2] }
  rev.reviewers.nodes[1].mergeRequestInteraction = { approved = false, reviewState = "UNREVIEWED" }
  fake:add(out)
  fake:add({
    { request = { method = "POST", path = ("/api/v4/projects/%s/merge_requests/%d/approve"):format(X.ENC, X.MR_IID) }, response = { status = 401, body = { message = "401 Unauthorized" } } },
  })
  s = stack.new()
  detail.merge_request(ctx(), { iid = X.MR_IID })
  local g = s:top().group
  H.wait_for(function()
    return table.concat(lines(g.members.sidebar.buf), "\n"):find("pending", 1, true) ~= nil
  end)
  local offered = choose("Approve")
  keys("A")
  eq(offered()[1], "Approve")
  H.wait_for(function()
    return last_note() and last_note():find("failed", 1, true) ~= nil
  end)
  eq(notes[#notes][2], vim.log.levels.ERROR)
  eq(written(fake).path, ("/api/v4/projects/%s/merge_requests/%d/approve"):format(X.ENC, X.MR_IID))
end

T["actions per state"] = function()
  eq(edits.actions("issue", { state = "opened" }), { open = true, actions = { "close" } })
  eq(edits.actions("issue", { state = "closed" }).actions, { "reopen" })
  eq(edits.actions("milestone", { state = "closed" }).actions, { "activate" })
  eq(edits.actions("merge_request", { state = "opened", draft = true }).actions, { "approve", "ready", "close" })
  eq(edits.actions("merge_request", { state = "merged" }), { open = false, actions = {} })
  eq(edits.actions("merge_request", { state = "closed" }).actions, { "reopen" })
end

T["issue: A closes and the picker below refreshes"] = function()
  local fake = H.fake()
  fake:add(X.issue_responses())
  fake:add({ X.issue_put({ state_event = "close" }, { state = "closed" }) })
  s = stack.new()
  -- a screen below that records refreshes
  local refreshed = {}
  local below_group = require("gg.ui.components.float_group").new({ layout = function()
    return { x = { row = 0, col = 0, width = 10, height = 1 } }
  end })
  below_group:add({ name = "x", enter = true })
  s:adopt({ group = below_group, refresh = function(_, kinds)
    table.insert(refreshed, kinds)
  end })
  detail.issue(ctx(), { iid = 214 })
  local g = s:top().group
  H.wait_for(function()
    return lines(g.members.content.buf)[2] == " Rotate the credentials of the state backend."
  end)
  choose("Close issue")
  keys("A")
  H.wait_for(function()
    return lines(g.members.header.buf)[2]:find("Closed", 1, true) ~= nil
  end)
  eq(fake:last().json, { state_event = "close" })
  keys("q")
  eq(refreshed, { { issue = true } })
end

return T
