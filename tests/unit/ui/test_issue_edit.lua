-- Editing an issue from its detail view: description in place, task toggle,
-- title / assignees / labels / milestone / dates in overlays.
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
      saved = { columns = vim.o.columns, lines = vim.o.lines, notify = vim.notify, utc = date.utc_offset }
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

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function last_note()
  return notes[#notes] and notes[#notes][1]
end

-- open #214 and wait until everything has loaded
local function open(extra)
  local fake = H.fake()
  fake:add(X.issue_responses())
  fake:add({ X.members(), X.labels_list(), X.milestones_list() })
  fake:add(extra or {})
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
  }, { iid = 214 })
  local g = s:top().group
  H.wait_for(function()
    local side = table.concat(lines(g.members.sidebar.buf), "\n")
    return lines(g.members.content.buf)[2] == " Rotate the credentials of the state backend." and side:find("!88", 1, true) ~= nil
  end)
  return g, fake
end

local function footer(win)
  local f = vim.api.nvim_win_get_config(win).footer
  return f and table.concat(vim.tbl_map(function(c)
    return c[1]
  end, f)) or nil
end

-- the overlay is the current window after an edit key
local function overlay_set(text)
  -- some overlays load their completion list first
  H.wait_for(function()
    return vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).zindex == 200
  end)
  local win = vim.api.nvim_get_current_win()
  eq(vim.api.nvim_win_get_config(win).zindex, 200) -- the overlay
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { text })
  return win
end

T["edits: split, token, diff, resolve, match, toggle_task, branch_name, date"] = function()
  eq(edits.split(" a, @b ,, A ,~c "), { "a", "b", "c" })
  eq({ edits.token("ann, bo", 7, true) }, { 5, "bo" })
  eq({ edits.token("ann, @bo", 8, true) }, { 6, "bo" })
  eq({ edits.token("2026.1", 6, false) }, { 0, "2026.1" })
  eq({ edits.diff({ "a", "B" }, { "b", "c" }) }, { { "c" }, { "a" } })
  local found, unknown = edits.resolve({ "ANN", "zed" }, { { n = "ann" }, { n = "bob" } }, function(x)
    return x.n
  end)
  eq({ found, unknown }, { { { n = "ann" } }, { "zed" } })
  local c = { { word = "docs" }, { word = "security" }, { word = "user-1", menu = "Ann Example" } }
  -- prefixes first, then substrings of the word or its menu text
  eq(edits.match("s", c), { { word = "security" }, { word = "docs" }, { word = "user-1", menu = "Ann Example" } })
  eq(edits.match("ann", c), { { word = "user-1", menu = "Ann Example" } })
  eq(edits.match("", c, { "docs" }), { { word = "security" }, { word = "user-1", menu = "Ann Example" } })
  eq({ edits.toggle_task("a\n- [ ] x\n  * [X] y", 2) }, { "a\n- [x] x\n  * [X] y", true })
  eq({ edits.toggle_task("a\n- [ ] x\n  * [X] y", 3) }, { "a\n- [ ] x\n  * [ ] y", false })
  eq(edits.toggle_task("a", 1), nil)
  eq(edits.branch_name(214, "Rotate Terraform: state / backend!"), "214-rotate-terraform-state-backend")
  eq(#edits.branch_name(1, string.rep("word ", 30)) <= 50, true)
  eq({ edits.date(""), edits.date("2026-11-01"), edits.date("tomorrow"), edits.date("2026-13-01") }, { false, "2026-11-01", nil, nil })
  eq(edits.mentions({ author = { username = "a", name = "A" }, assignees = { { username = "b" }, { username = "a" } } }, {
    { notes = { { system = false, author = { username = "c" } }, { system = true, author = { username = "d" } } } },
  }), { { word = "a", menu = "A" }, { word = "b" }, { word = "c" } })
end

T["i edits the description in place; <C-s> saves"] = function()
  local g, fake = open({
    X.issue_get(),
    X.issue_put({ description = "New text.\n- [ ] one" }, { description = "New text.\n- [ ] one" }),
  })
  local win = g.members.content.win
  local tab_buf = vim.api.nvim_win_get_buf(win)
  keys("i")
  H.wait_for(function()
    return vim.api.nvim_win_get_buf(win) ~= tab_buf
  end)
  vim.cmd("stopinsert")
  local ebuf = vim.api.nvim_win_get_buf(win)
  eq(lines(ebuf)[1], "Rotate the credentials of the state backend.") -- the raw markdown
  eq(vim.bo[ebuf].filetype, "markdown")
  eq(vim.wo[win].winhighlight:find("GitlabDetailBorderEditing", 1, true) ~= nil, true)
  eq(footer(win), " [<C-s>] Save • [<Esc>] Cancel ")
  vim.api.nvim_buf_set_lines(ebuf, 0, -1, false, { "New text.", "- [ ] one" })
  keys("<C-s>")
  H.wait_for(function()
    return vim.api.nvim_win_get_buf(win) == tab_buf
  end)
  eq(lines(tab_buf)[2], " New text.")
  eq(lines(tab_buf)[3], " ○ one")
  eq(fake:last().json.description, "New text.\n- [ ] one")
  eq(last_note(), "gg.ui: Description updated")
  eq(vim.wo[win].winhighlight:find("GitlabDetailBorderEditing", 1, true), nil)
  eq(footer(win), " [i] Edit ")
end

T["<Esc> cancels the description edit; nothing is sent"] = function()
  local g, fake = open({ X.issue_get() })
  local win = g.members.content.win
  local tab_buf = vim.api.nvim_win_get_buf(win)
  keys("i")
  H.wait_for(function()
    return vim.api.nvim_win_get_buf(win) ~= tab_buf
  end)
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { "draft" })
  keys("<Esc>")
  eq(vim.api.nvim_win_get_buf(win), tab_buf)
  for _, r in ipairs(fake:requests()) do
    eq(r.method ~= "PUT", true)
  end
  eq(lines(tab_buf)[2], " Rotate the credentials of the state backend.")
end

T["x toggles a task at once; an error rolls it back"] = function()
  local g, fake = open({ X.issue_put({}, nil, { status = 500 }) })
  local win = g.members.content.win
  vim.api.nvim_win_set_cursor(win, { 6, 0 }) -- " ○ old key revoked"
  eq(lines(g.members.content.buf)[6], " ○ old key revoked")
  -- the hint on the task line
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = g.members.content.buf })
  local marks = vim.api.nvim_buf_get_extmarks(g.members.content.buf, -1, { 5, 0 }, { 5, -1 }, { details = true })
  local hint
  for _, m in ipairs(marks) do
    if m[4].virt_text then
      hint = m[4].virt_text
    end
  end
  eq(hint, { { "[x]", "GitlabHintKey" }, { " toggle", "GitlabHintText" } })
  keys("x")
  eq(lines(g.members.content.buf)[6], " ✓ old key revoked") -- optimistic
  H.wait_for(function()
    return last_note() and last_note():find("failed", 1, true) ~= nil
  end)
  eq(lines(g.members.content.buf)[6], " ○ old key revoked") -- rolled back
  eq(fake:last().json.description:find("- [x] old key revoked", 1, true) ~= nil, true)
end

T["gt edits the title over the header"] = function()
  local g, fake = open({ X.issue_put({ title = "A new title" }, { title = "A new title" }) })
  keys("gt")
  local ow = overlay_set("A new title")
  local pos = vim.api.nvim_win_get_config(ow)
  local hdr = vim.api.nvim_win_get_position(g.members.header.win)
  eq(pos.row, hdr[1] + 1 + 1) -- border + the empty line above the title
  keys("<C-s>")
  H.wait_for(function()
    return lines(g.members.header.buf)[2]:find("A new title", 1, true) ~= nil
  end)
  eq(fake:last().json, { title = "A new title" })
  eq(vim.api.nvim_win_is_valid(ow), false)
  eq(vim.api.nvim_get_current_win(), g.members.content.win)
end

T["ga, gl, gM: completion, payloads, unknown values"] = function()
  local g, fake = open({
    X.issue_put({ assignee_ids = { 3 } }, { assignees = { X.rest_user(3, "Cid Third") } }),
    X.issue_put({ add_labels = "docs", remove_labels = "terraform" }, { labels = { "security", "docs" } }),
    X.issue_put({ milestone_id = 0 }, { milestone = vim.NIL }),
  })
  -- assignees: completion from the members, ids sent
  keys("ga")
  H.wait_for(function()
    return vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).zindex == 200
  end)
  eq(table.concat(lines(g.members.sidebar.buf), "\n"):find("ASSIGNEE", 1, true) ~= nil, true)
  local ow = overlay_set("user-3, nobody")
  local field = require("gg.ui.components.field_edit")
  -- the label is orange while edited
  local marks = vim.api.nvim_buf_get_extmarks(g.members.sidebar.buf, -1, 0, -1, { details = true })
  local orange = false
  for _, m in ipairs(marks) do
    orange = orange or m[4].hl_group == "GitlabDetailLabelEditing"
  end
  eq(orange, true)
  keys("<C-s>")
  H.wait_for(function()
    return table.concat(lines(g.members.sidebar.buf), "\n"):find("Cid Third", 1, true) ~= nil
  end)
  eq(fake:last().json.assignee_ids, { 3 })
  local warned = false
  for _, n in ipairs(notes) do
    warned = warned or n[1] == "gg.ui: Skipping unrecognized: nobody"
  end
  eq(warned, true)
  eq(vim.api.nvim_win_is_valid(ow), false)
  _ = field
  -- labels: add / remove
  keys("gl")
  overlay_set("security, docs")
  keys("<C-s>")
  H.wait_for(function()
    return fake:last().json.add_labels ~= nil
  end)
  eq({ fake:last().json.add_labels, fake:last().json.remove_labels }, { "docs", "terraform" })
  -- milestone: unknown is refused (the overlay stays), empty removes it
  H.wait_for(function()
    return vim.api.nvim_get_current_win() == g.members.content.win
  end)
  keys("gM")
  ow = overlay_set("no such milestone")
  keys("<C-s>")
  eq(last_note(), "gg.ui: Unknown milestone: no such milestone")
  eq(vim.api.nvim_win_is_valid(ow), true)
  overlay_set("")
  keys("<C-s>")
  H.wait_for(function()
    return fake:last().json.milestone_id ~= nil
  end)
  eq(fake:last().json.milestone_id, 0)
end

T["field overlay: completion of the value at the cursor, save and cancel"] = function()
  local cfg = config.get()
  local asked, closed, saved_text = {}, {}, nil
  local f = require("gg.ui.components.field_edit").open({
    row = 2,
    col = 4,
    width = 30,
    text = "security, d",
    multi = true,
    keys = cfg.keymaps,
    complete = function(query, cb)
      table.insert(asked, query)
      cb({ { word = "docs" }, { word = "security" }, { word = "dev" } })
    end,
    on_save = function(t, done)
      saved_text = t
      done(true)
    end,
    on_close = function(ok)
      table.insert(closed, ok)
    end,
  })
  vim.cmd("stopinsert")
  local cfgw = vim.api.nvim_win_get_config(f.win)
  eq({ cfgw.row, cfgw.col, cfgw.width, cfgw.height, cfgw.zindex }, { 2, 4, 30, 1, 200 })
  f:complete_now()
  eq(asked, { "d" })
  -- "security" is typed already
  eq(vim.tbl_map(function(c)
    return c.word
  end, f.last_items), { "docs", "dev" })
  keys("<C-s>")
  eq({ saved_text, closed }, { "security, d", { true } })
  eq(vim.api.nvim_win_is_valid(f.win), false)
  -- cancel with <Esc> in normal mode
  closed = {}
  f = require("gg.ui.components.field_edit").open({
    row = 2, col = 4, width = 10, text = "x", keys = cfg.keymaps,
    on_save = function() end,
    on_close = function(ok)
      table.insert(closed, ok)
    end,
  })
  vim.cmd("stopinsert")
  eq(vim.api.nvim_win_get_config(f.win).width, 24) -- at least MIN_WIDTH
  -- near the limit the overlay moves left instead of shrinking
  local place = require("gg.ui.components.field_edit").place
  eq({ place(4, 10, 100) }, { 4, 24 })
  eq({ place(90, 8, 100) }, { 76, 24 })
  eq({ place(5, 8, 20) }, { 0, 20 })
  keys("<Esc>")
  eq(closed, { false })
end

T["gd edits the due date; a bad date is refused"] = function()
  local g, fake = open({ X.dates_update("2026-11-01", "2026-12-01") })
  keys("gd")
  local ow = overlay_set("someday")
  keys("<C-s>")
  eq(last_note(), "gg.ui: Not a date (YYYY-MM-DD): someday")
  overlay_set("2026-12-01")
  keys("<C-s>")
  H.wait_for(function()
    return table.concat(lines(g.members.sidebar.buf), "\n"):find("2026-12-01", 1, true) ~= nil
  end)
  local req = fake:last()
  eq({ req.operation, req.variables.dueDate, req.variables.id }, { "WorkItemUpdateDates", "2026-12-01", "gid://gitlab/WorkItem/9214" })
  eq(vim.api.nvim_win_is_valid(ow), false)
end

T["a closed issue refuses edits but labels"] = function()
  local fake = H.fake()
  local node = X.issue_node()
  node.state = "closed"
  fake:add({ X.issue_get(node), X.dates(), X.branches({}), X.related_mrs({}), X.current_user(), X.labels_list() })
  s = stack.new()
  detail.issue({ stack = s, cfg = config.get(), host = X.HOST, project = X.PROJECT, today = X.TODAY }, { iid = 214 })
  local g = s:top().group
  H.wait_for(function()
    return lines(g.members.header.buf)[2]:find("Closed", 1, true) ~= nil
  end)
  keys("gt")
  eq(last_note(), "gg.ui: Issue is closed")
  eq(footer(g.members.content.win), nil) -- no [i] Edit on a closed issue
  local side = table.concat(lines(g.members.sidebar.buf), "\n")
  eq(side:find("[ga]", 1, true), nil)
  eq(side:find("[gl]", 1, true) ~= nil, true)
end

return T
