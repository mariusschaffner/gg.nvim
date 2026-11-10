-- The issue detail view end to end: real windows, fake backend.
local H = require("tests.helpers")
local X = require("tests.support.detail_data")
local config = require("gg.ui.config")
local date = require("gg.ui.lib.date")
local detail = require("gg.ui.detail")
local stack = require("gg.ui.components.stack")
local eq = MiniTest.expect.equality

local s -- the stack under test
local saved = {}

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { columns = vim.o.columns, lines = vim.o.lines, notify = vim.notify, utc = date.utc_offset }
      vim.o.columns, vim.o.lines = 170, 50
      date.utc_offset = function()
        return 0
      end
    end,
    post_case = function()
      if s and not s:is_closed() then
        s:close()
      end
      s = nil
      vim.notify = saved.notify
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

local function open(responses)
  local fake = H.fake()
  fake:add(responses or X.issue_responses())
  s = stack.new()
  detail.issue({
    stack = s,
    cfg = config.get(),
    host = X.HOST,
    project = X.PROJECT,
    today = X.TODAY,
    now = function()
      return date.parse_time(X.NOW)
    end,
  }, { iid = 214, title = "Rotate Terraform state backend credentials", state = "opened" })
  local v = s:top()
  return v, fake
end

local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function chunks_text(chunks)
  return table.concat(vim.tbl_map(function(c)
    return c[1]
  end, chunks))
end

-- the content, header and sidebar buffers of the top screen
local function wins()
  local g = s:top().group
  return g.members.header, g.members.content, g.members.sidebar
end

local function loaded()
  H.wait_for(function()
    local _, content = wins()
    local l = buf_lines(content.buf)
    return #l > 2 and l[2]:find("Rotate the credentials", 1, true) ~= nil
  end)
  H.wait_for(function()
    local header, _, side = wins()
    local text = table.concat(buf_lines(side and side.buf or header.buf), "\n")
    -- the header strip says "no branch" until the branches have loaded
    return not text:find("Loading", 1, true) and not text:find("no branch", 1, true)
  end)
end

T["opens on top, loads the issue, renders header, description and sidebar"] = function()
  open()
  local header, content, side = wins()
  -- first frame: what the caller passed, loading placeholders
  eq(buf_lines(content.buf), { "", " Loading…" }) -- below an empty first line
  eq(vim.api.nvim_get_current_win(), content.win)
  loaded()
  local hl = buf_lines(header.buf)
  eq(hl[1], "")
  eq(vim.startswith(hl[2], "  ● Open  Rotate Terraform state backend credentials #214"), true)
  eq(hl[3], "")
  eq(hl[4]:find(" security   terraform   ◆ 2026.11 Patch cycle  │  ● ○ 1/2 criteria", 1, true) ~= nil, true)
  eq(hl[5], "")
  local title = chunks_text(vim.api.nvim_win_get_config(header.win).title)
  eq(vim.startswith(title, " issues › #214 "), true)
  eq(vim.endswith(title, " opened by User One · updated 1w ago "), true)
  local cl = buf_lines(content.buf)
  eq(cl[1], "")
  eq(cl[2], " Rotate the credentials of the state backend.")
  eq(cl[4]:match("^ Acceptance%s+1 of 2 done$") ~= nil, true)
  eq(cl[5], " ✓ new key in the vault")
  eq(cl[6], " ○ old key revoked")
  local sl = buf_lines(side.buf)
  eq(sl[1], "")
  eq(sl[2], " ASSIGNEE")
  eq(sl[3], " (US) User")
  eq(table.concat(sl, "\n"):find(" 2026-11-01          2026-11-14", 1, true) ~= nil, true)
  eq(table.concat(sl, "\n"):find("⎇ 214-rotate-credentials", 1, true) ~= nil, true)
  eq(table.concat(sl, "\n"):find("!88 Rotate Terraform", 1, true) ~= nil, true)
  -- tabs in the content title, hints in its footer
  local cfg = vim.api.nvim_win_get_config(content.win)
  eq(chunks_text(cfg.title), " Description · Activity ") -- no comment count
  eq(chunks_text(cfg.footer), " [i] Edit ")
  -- the edit key only says that editing comes later
  local notes = {}
  local notify = vim.notify
  vim.notify = function(msg)
    table.insert(notes, msg)
  end
  keys("i")
  vim.notify = notify
  eq(notes, { "gg.ui: editing is not available yet" })
end

T["Activity loads on first show; za folds a thread"] = function()
  local _, fake = open()
  loaded()
  local before = #fake:requests()
  for _, r in ipairs(fake:requests()) do
    eq(r.operation ~= "IssueDiscussions", true)
  end
  keys("<Tab>")
  local _, content = wins()
  H.wait_for(function()
    return (buf_lines(vim.api.nvim_win_get_buf(content.win))[2] or ""):find("YESTERDAY", 1, true) ~= nil
  end)
  eq(#fake:requests() > before, true)
  local l = buf_lines(vim.api.nvim_win_get_buf(content.win))
  eq(l[1], "")
  eq(l[2]:find(" YESTERDAY · 09.11.2026 ─", 1, true) ~= nil, true)
  eq(vim.startswith(l[3], "   ◈  Ann Example added ~docs label"), true)
  eq(l[5]:find(" TODAY · 10.11.2026 ", 1, true) ~= nil, true)
  eq(vim.startswith(l[6], "  ▎ AE Ann Example  09:00  you"), true)
  eq(vim.startswith(l[8], "      └─ ▎ BS Bob Sample  09:30"), true)
  -- no key hints under the timeline
  eq(vim.api.nvim_win_get_config(content.win).footer, nil) -- no footer, an unbroken border
  vim.api.nvim_win_set_cursor(content.win, { 7, 0 })
  keys("za")
  l = buf_lines(vim.api.nvim_win_get_buf(content.win))
  eq(l[8], "     ▸ 1 reply · [za] expand")
  eq(vim.api.nvim_win_get_cursor(content.win)[1], 6)
  vim.api.nvim_win_set_cursor(content.win, { 8, 0 })
  keys("<CR>")
  eq(vim.startswith(buf_lines(vim.api.nvim_win_get_buf(content.win))[8], "      └─ ▎ BS Bob Sample"), true)
  local activity_buf = vim.api.nvim_win_get_buf(content.win)
  keys("<S-Tab>")
  eq(vim.api.nvim_win_get_buf(content.win) ~= activity_buf, true)
  eq(buf_lines(vim.api.nvim_win_get_buf(content.win))[2], " Rotate the credentials of the state backend.")
end

T["gm and gp open the milestone and the merge request; q goes back"] = function()
  open()
  loaded()
  local got = {}
  local real = { milestone = detail.milestone, merge_request = detail.merge_request }
  detail.milestone = function(ctx, m)
    got.milestone = { m.title, ctx.project, ctx.stack == s }
  end
  detail.merge_request = function(_, mr)
    got.mr = mr.iid
  end
  local ok, err = pcall(function()
    keys("gm")
    keys("gp")
  end)
  detail.milestone, detail.merge_request = real.milestone, real.merge_request
  assert(ok, err)
  eq(got, { milestone = { "2026.11 Patch cycle", X.PROJECT, true }, mr = 88 })
  keys("q")
  eq(s:is_closed(), true)
end

T["narrow: no sidebar, a meta strip in the header"] = function()
  vim.o.columns = 90
  open()
  loaded()
  local header, _, side = wins()
  eq(side, nil)
  eq(buf_lines(header.buf)[5], " Open · @user-ma · security · ◆ 2026.11 Patch cycle · due 2026-11-14 · 214-rotate-cred…") -- cut to the width
end

T["load error shows in the description; R retries"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "IssueGet" }, response = { status = 500, body = { message = "boom" } } })
  fake:add(X.dates())
  fake:add(X.branches({}))
  fake:add(X.related_mrs({}))
  s = stack.new()
  detail.issue({ stack = s, cfg = config.get(), host = X.HOST, project = X.PROJECT, today = X.TODAY }, { iid = 214 })
  local _, content = wins()
  H.wait_for(function()
    local l = buf_lines(content.buf)[2] or ""
    return l:find("500", 1, true) ~= nil or l:find("boom", 1, true) ~= nil
  end)
  fake:add(X.issue_responses())
  keys("R")
  loaded()
  local _, _, side = wins()
  eq(table.concat(buf_lines(side.buf), "\n"):find("!88", 1, true) ~= nil, true)
end

return T
