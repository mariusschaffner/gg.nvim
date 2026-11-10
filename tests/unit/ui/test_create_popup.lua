-- The creation popup (real windows, headless): layout, labels, focus cycle,
-- cancel, submit, errors. Uses the issue view, the simplest definition.
local H = require("tests.helpers")
local P = require("tests.support.create_data")
local X = require("tests.support.detail_data")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = { pre_case = P.pre_case, post_case = P.post_case } })

local ISSUES = "/api/v4/projects/" .. X.ENC .. "/issues"

T["opens over 70 % of the editor with the K4 floats and labels"] = function()
  local p = P.open("issue")
  local m = p.group.members
  -- 170 x 50: the command line takes one row -> a 119 x 34 box at 25, 7
  local function geo(win)
    local c = vim.api.nvim_win_get_config(win)
    return { c.row, c.col, c.width, c.height }
  end
  eq(geo(m.title.win), { 7, 25, 117, 1 })
  eq(geo(m.body.win), { 11, 25, 117, 28 })
  eq(P.title(m.title.win), " ＋ New issue ")
  eq(vim.api.nvim_win_get_config(m.title.win).title[1][2], "GitlabCreateIssue")
  eq(P.title(m.body.win), " [i] Edit " .. string.rep("─", 99) .. " Issue ─")
  eq(P.footer(m.body.win), " [<Tab>] Title ⇄ description • [<Esc><Esc>] Cancel " .. string.rep("─", 49) .. " [<C-s>] Create ─")
  -- the title float keeps its accent colour; the focused float is active
  eq(vim.wo[m.title.win].winhighlight:find("FloatBorder:GitlabCreateIssue", 1, true) ~= nil, true)
  local wo = vim.wo[m.body.win]
  eq({ wo.number, wo.cursorline, wo.wrap, wo.linebreak, wo.signcolumn }, { true, true, true, true, "no" })
  eq(vim.bo[m.body.buf].filetype, "markdown")
  -- an empty title: the cursor starts there, in insert mode, with a placeholder
  eq(vim.api.nvim_get_current_win(), m.title.win)
  eq(P.virt(m.title.buf), { "title" })
  vim.api.nvim_buf_set_lines(m.title.buf, 0, -1, false, { "Fix it" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = m.title.buf })
  eq(P.virt(m.title.buf), {})
end

T["resizes with the editor"] = function()
  local p = P.open("issue")
  vim.o.columns, vim.o.lines = 120, 40
  H.flush(20)
  local c = vim.api.nvim_win_get_config(p.group.members.body.win)
  eq({ c.col, c.width }, { 18, 82 })
  eq(vim.fn.strdisplaywidth(P.title(p.group.members.body.win)), 82)
  eq(vim.fn.strdisplaywidth(P.footer(p.group.members.body.win)), 82)
end

T["Tab cycles title and body, also from insert mode in the title"] = function()
  local p = P.open("issue")
  local m = p.group.members
  eq(vim.fn.maparg("<Tab>", "i", false, true).buffer, 1) -- mapped while typing the title
  P.keys("<Tab>")
  eq(vim.api.nvim_get_current_win(), m.body.win)
  eq(vim.api.nvim_get_mode().mode, "n")
  eq(vim.wo[m.body.win].winhighlight:find("FloatBorder:GitlabPickerBorderActive", 1, true) ~= nil, true)
  P.keys("<Tab>")
  eq(vim.api.nvim_get_current_win(), m.title.win)
  P.keys("<S-Tab>")
  eq(vim.api.nvim_get_current_win(), m.body.win)
end

T["a preset title starts in the body; the title stays one line"] = function()
  local p = P.open("issue", { title = "feat(docs): add sprint-3 planning", description = "I want to ‹what›\nSo that ‹why›" })
  local m = p.group.members
  eq(P.lines(m.title.buf), { "feat(docs): add sprint-3 planning" })
  eq(P.lines(m.body.buf), { "I want to ‹what›", "So that ‹why›" })
  eq(vim.api.nvim_get_current_win(), m.body.win)
  eq(p:dirty(), false) -- a prefill is not a change
  -- the first placeholder is selected: typing replaces it
  H.wait_for(function()
    return vim.api.nvim_get_mode().mode == "s"
  end)
  P.keys("ship")
  eq(P.lines(m.body.buf)[1], "I want to ship")
  vim.cmd("stopinsert")
  P.keys("<C-n>")
  H.wait_for(function()
    return vim.api.nvim_get_mode().mode == "s"
  end)
  P.keys("we can plan")
  eq(P.lines(m.body.buf)[2], "So that we can plan")
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(m.title.buf, 0, -1, false, { "a", "b" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = m.title.buf })
  eq(P.lines(m.title.buf), { "a b" })
end

T["Esc Esc closes at once when nothing changed"] = function()
  local p, s = P.open("issue")
  vim.cmd("stopinsert")
  P.keys("<Esc><Esc>")
  eq({ p.closed, s:depth() }, { true, 1 })
end

T["Esc Esc asks before discarding changes"] = function()
  local p, s = P.open("issue")
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(p.title_float.buf, 0, -1, false, { "draft" })
  local asked
  vim.ui.input = function(opts, cb)
    asked = opts.prompt
    cb("n")
  end
  P.keys("<Esc><Esc>")
  eq(asked, "Discard changes? [y/N]: ")
  eq({ p.closed, s:depth() }, { false, 2 })
  vim.ui.input = function(_, cb)
    cb("y")
  end
  P.keys("<Esc><Esc>")
  eq({ p.closed, s:depth() }, { true, 1 })
end

T["<C-s> creates the issue (with the hidden milestone) and opens it"] = function()
  local responses = X.issue_responses()
  table.insert(responses, {
    request = { method = "POST", path = ISSUES, body_contains = { title = "Rotate keys", description = "Because.\n\nNow.", milestone_id = 11 } },
    response = { status = 201, delay = 30, body = X.rest_issue() },
  })
  local p, s, fake = P.open("issue", { milestone_id = 11 }, responses)
  local m = p.group.members
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(m.title.buf, 0, -1, false, { "  Rotate keys " })
  vim.api.nvim_buf_set_lines(m.body.buf, 0, -1, false, { "Because.", "", "Now.", "", "" })
  local below = s.screens[1]
  P.keys("<C-s>")
  -- while it runs: the label says so and nothing can be edited
  eq(P.footer(m.body.win):find(" creating… ─", 1, true) ~= nil, true)
  eq({ vim.bo[m.body.buf].modifiable, vim.bo[m.title.buf].modifiable }, { false, false })
  P.keys("<C-s>") -- a second submit is ignored
  H.wait_for(function()
    return p.closed and s:depth() == 2
  end)
  -- the new issue's detail view took the popup's place; the table below reloads
  H.wait_for(function()
    return s:top().group.members.header ~= nil
  end)
  eq(below.dirty, { issue = true, milestone = true })
  local posts = vim.tbl_filter(function(r)
    return r.method == "POST" and r.path == ISSUES
  end, fake:requests())
  eq(#posts, 1)
  eq(posts[1].json, { title = "Rotate keys", description = "Because.\n\nNow.", milestone_id = 11 })
end

T["an empty title is refused, in the title float"] = function()
  local p, _, fake = P.open("issue")
  local m = p.group.members
  vim.cmd("stopinsert")
  p:focus("body")
  P.keys("<C-s>")
  eq(#fake:requests(), 0)
  eq(P.diagnostics(p, m.title.buf), { "Title cannot be empty" })
  eq(P.footer(m.body.win):find(" Title cannot be empty ─", 1, true) ~= nil, true)
  eq(vim.api.nvim_win_get_config(m.body.win).footer[#vim.api.nvim_win_get_config(m.body.win).footer - 1][2], "GitlabCreateError")
  eq(vim.api.nvim_get_current_win(), m.title.win)
  eq(P.notes[#P.notes], { "gg.ui: Title cannot be empty", vim.log.levels.WARN })
  -- editing clears the error
  vim.api.nvim_buf_set_lines(m.title.buf, 0, -1, false, { "x" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = m.title.buf })
  eq(P.diagnostics(p, m.title.buf), {})
  eq(P.footer(m.body.win):find(" [<C-s>] Create ─", 1, true) ~= nil, true)
end

T["an API error keeps the popup; field errors go to their float"] = function()
  local p, s = P.open("issue", nil, {
    {
      request = { method = "POST", path = ISSUES },
      response = { status = 400, body = { message = { title = { "is too long (maximum is 255 characters)" }, description = { "is too long" } } } },
    },
    { request = { method = "POST", path = ISSUES }, response = { status = 403, body = { message = "403 Forbidden" } } },
  })
  local m = p.group.members
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(m.title.buf, 0, -1, false, { "long" })
  vim.api.nvim_buf_set_lines(m.body.buf, 0, -1, false, { "text" })
  P.keys("<C-s>")
  H.wait_for(function()
    return p.state == "error"
  end)
  eq({ p.closed, s:depth() }, { false, 2 })
  eq(P.lines(m.title.buf), { "long" })
  eq(P.lines(m.body.buf), { "text" })
  eq({ vim.bo[m.body.buf].modifiable, vim.bo[m.title.buf].modifiable }, { true, true })
  eq(P.diagnostics(p, m.title.buf), { "is too long (maximum is 255 characters)" })
  eq(P.diagnostics(p, m.body.buf), { "is too long" })
  eq(P.notes[#P.notes][2], vim.log.levels.ERROR)
  eq(P.notes[#P.notes][1]:find("New issue failed: 400 Bad Request", 1, true) ~= nil, true)
  -- an error that names no field: the border and the notification
  P.keys("<C-s>")
  H.wait_for(function()
    return P.footer(m.body.win):find(" 403 Forbidden ─", 1, true) ~= nil
  end)
  eq(P.diagnostics(p, m.title.buf), {})
end

T["the popup closes with the stack and cancels its request"] = function()
  local p, s = P.open("issue", nil, {
    { request = { method = "POST", path = ISSUES }, response = { status = 201, delay = 200, body = X.rest_issue() } },
  })
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(p.title_float.buf, 0, -1, false, { "x" })
  P.keys("<C-s>")
  eq(p.state, "busy")
  s:close()
  eq(p.closed, true)
  H.flush(250)
  eq(s:is_closed(), true)
end

return T
