-- Comments on the Activity tab: the docked box, replies, edits, deletes,
-- resolving threads.
local H = require("tests.helpers")
local X = require("tests.support.detail_data")
local config = require("gg.ui.config")
local date = require("gg.ui.lib.date")
local detail = require("gg.ui.detail")
local stack = require("gg.ui.components.stack")
local eq = MiniTest.expect.equality

local s
local saved = {}
local notes

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { columns = vim.o.columns, lines = vim.o.lines, notify = vim.notify, utc = date.utc_offset, input = vim.ui.input }
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
      vim.notify, vim.ui.input = saved.notify, saved.input
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

local BASE = "/api/v4/projects/" .. X.ENC .. "/issues/214"

-- the issue's discussions, resolvable thread t1, repeated (reloads)
local function discussions()
  local e = X.issue_discussions()
  e["repeat"] = true
  local t1 = e.response.body.data.project.issue.discussions.nodes[2]
  t1.resolvable = true
  return e
end

local function open(extra)
  local fake = H.fake()
  local base = X.issue_responses()
  base[5] = discussions()
  fake:add(base)
  fake:add(extra or {})
  s = stack.new()
  detail.issue({ stack = s, cfg = config.get(), host = X.HOST, project = X.PROJECT, today = X.TODAY }, { iid = 214 })
  local g = s:top().group
  H.wait_for(function()
    return lines(g.members.content.buf)[2] == " Rotate the credentials of the state backend."
  end)
  keys("<Tab>")
  local win = g.members.content.win
  H.wait_for(function()
    return g.members.dock ~= nil and lines(g.members.dock.buf)[1]:find("write a new comment", 1, true) ~= nil
  end)
  return g, fake, win
end

local function composer_set(text)
  H.wait_for(function()
    return vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).zindex == 150
  end)
  vim.cmd("stopinsert")
  local w = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(w), 0, -1, false, vim.split(text, "\n"))
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = vim.api.nvim_win_get_buf(w) })
  return w
end

local function row_of(win, pat)
  for i, l in ipairs(lines(vim.api.nvim_win_get_buf(win))) do
    if l:find(pat, 1, true) then
      return i
    end
  end
end

local function rest_note(id, body)
  return { id = id, body = body, author = X.rest_user(1, "Ann Example"), created_at = X.NOW, updated_at = X.NOW, system = false }
end

T["the box at the end; i posts a new comment and follows it"] = function()
  local g, fake, win = open({
    {
      request = { method = "POST", path = BASE .. "/discussions", body_contains = { body = "Hello there" } },
      response = { status = 201, body = { id = "new1", individual_note = true, notes = { rest_note(9, "Hello there") } } },
    },
  })
  -- the box is pinned inside the bottom of the Activity box, not in the timeline
  local dock = g.members.dock
  local dl = lines(dock.buf)[1]
  eq(vim.startswith(dl, "  AE  › write a new comment…"), true)
  eq(vim.endswith(dl, "[i] Comment"), true)
  eq(vim.fn.strdisplaywidth(dl), vim.api.nvim_win_get_width(dock.win) - 1) -- one column of margin
  local tl = lines(vim.api.nvim_win_get_buf(win))
  eq(tl[#tl]:find("write a new comment", 1, true), nil)
  eq({ tl[#tl], tl[#tl - 1], tl[#tl - 2] }, { "", "", "" }) -- room for the box
  local dpos, cpos = vim.api.nvim_win_get_position(dock.win), vim.api.nvim_win_get_position(win)
  eq(dpos[1] + 1 + 1, cpos[1] + vim.api.nvim_win_get_height(win)) -- its bottom border on the last row
  eq(dpos[2], cpos[2] + 1) -- inside the content box's left border
  -- the cursor stays above the box
  keys("G")
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(win) })
  eq(vim.api.nvim_win_get_cursor(win)[1], #tl - 3)
  eq(vim.wo[win].scrolloff, 3)
  -- other tabs have no box
  keys("<S-Tab>")
  eq(g.members.dock, nil)
  keys("<Tab>")
  eq(g.members.dock ~= nil, true)
  keys("i")
  local cw = composer_set("Hello there")
  eq(g.members.dock, nil) -- the composer takes its place
  local content_foot = vim.api.nvim_win_get_config(win).footer
  eq(content_foot == nil or content_foot == "" or #content_foot == 0, true) -- no Save / Cancel under the box
  local cfg = vim.api.nvim_win_get_config(cw)
  eq(cfg.title[1][1], " Comment ")
  local foot = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, cfg.footer))
  eq(foot, " [<C-s>] Post • [<Esc>] Cancel ● unsaved ")
  keys("<C-s>")
  H.wait_for(function()
    return last_note() == "gg.ui: Comment added"
  end)
  eq(vim.api.nvim_win_is_valid(cw), false)
  local post
  for _, r in ipairs(fake:requests()) do
    if r.method == "POST" and r.path == BASE .. "/discussions" then
      post = r
    end
  end
  eq(post.json, { body = "Hello there" })
  -- an empty comment is refused
  keys("i")
  composer_set("   ")
  keys("<C-s>")
  eq(last_note(), "gg.ui: the comment is empty")
  keys("<Esc>")
  eq(vim.api.nvim_get_current_win(), win)
end

T["gc replies under the thread (author seeded); <C-r> posts and resolves"] = function()
  local g, fake, win = open({
    {
      request = { method = "POST", path = BASE .. "/discussions/t1/notes", body_contains = { body = "@user-2 thanks" } },
      response = { status = 201, body = rest_note(10, "@user-2 thanks") },
    },
    { request = { operation = "DiscussionToggleResolve", variables = { id = "gid://gitlab/Discussion/t1", resolve = true } }, response = { body = { data = { discussionToggleResolve = { errors = {}, discussion = { id = "gid://gitlab/Discussion/t1", resolvable = true, resolved = true } } } } } },
  })
  -- on Bob's reply
  local r = row_of(win, "BS Bob Sample")
  vim.api.nvim_win_set_cursor(win, { r, 0 })
  -- the cursor hint
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(win) })
  local hint
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), -1, { r - 1, 0 }, { r - 1, -1 }, { details = true })) do
    if m[4].virt_text then
      hint = table.concat(vim.tbl_map(function(c)
        return c[1]
      end, m[4].virt_text))
    end
  end
  eq(hint, "[gc] reply · [gX] resolve")
  keys("gc")
  local cw = composer_set("@user-2 thanks")
  eq(lines(vim.api.nvim_win_get_buf(cw)), { "@user-2 thanks" })
  local cfg = vim.api.nvim_win_get_config(cw)
  eq(cfg.title[1][1], " ↩ Reply to thread ")
  eq(cfg.relative, "win")
  keys("<C-r>")
  H.wait_for(function()
    return last_note() == "gg.ui: Reply added"
  end)
  local ops = {}
  for _, q in ipairs(fake:requests()) do
    table.insert(ops, q.operation or (q.method .. " " .. q.path))
  end
  eq(vim.tbl_contains(ops, "POST " .. BASE .. "/discussions/t1/notes"), true)
  eq(vim.tbl_contains(ops, "DiscussionToggleResolve"), true)
end

T["gE edits and gD deletes only your own comments; gX resolves"] = function()
  local g, fake, win = open({
    {
      request = { method = "PUT", path = BASE .. "/discussions/t1/notes/2", body_contains = { body = "Which key first?" } },
      response = { body = rest_note(2, "Which key first?") },
    },
    { request = { method = "DELETE", path = BASE .. "/discussions/t1/notes/2" }, response = { status = 204 } },
    { request = { operation = "DiscussionToggleResolve" }, response = { body = { data = { discussionToggleResolve = { errors = {}, discussion = { id = "gid://gitlab/Discussion/t1", resolvable = true, resolved = true } } } } } },
  })
  -- Bob's comment is not yours
  vim.api.nvim_win_set_cursor(win, { row_of(win, "BS Bob Sample"), 0 })
  keys("gE")
  eq(last_note(), "gg.ui: Only your own comments can be changed")
  -- your comment: edit, seeded with its body
  vim.api.nvim_win_set_cursor(win, { row_of(win, "AE Ann Example") + 1, 0 })
  keys("gE")
  local cw = composer_set("Which key first?")
  keys("<C-s>")
  H.wait_for(function()
    return last_note() == "gg.ui: Comment updated"
  end)
  eq(vim.api.nvim_win_is_valid(cw), false)
  -- delete asks first
  vim.ui.input = function(opts, cb)
    eq(opts.prompt, "Delete comment? [y/N]: ")
    cb("y")
  end
  vim.api.nvim_win_set_cursor(win, { row_of(win, "AE Ann Example"), 0 })
  keys("gD")
  H.wait_for(function()
    return last_note() == "gg.ui: Comment deleted"
  end)
  -- resolve the thread
  vim.api.nvim_win_set_cursor(win, { row_of(win, "BS Bob Sample"), 0 })
  keys("gX")
  H.wait_for(function()
    return last_note() == "gg.ui: Thread resolved"
  end)
  local methods = {}
  for _, q in ipairs(fake:requests()) do
    table.insert(methods, q.operation or q.method)
  end
  eq(vim.tbl_contains(methods, "PUT") and vim.tbl_contains(methods, "DELETE") and vim.tbl_contains(methods, "DiscussionToggleResolve"), true)
end

T["a closed issue takes no comments"] = function()
  local fake = H.fake()
  local node = X.issue_node()
  node.state = "closed"
  fake:add({ X.issue_get(node), X.dates(), X.branches({}), X.related_mrs({}), discussions(), X.current_user() })
  s = stack.new()
  detail.issue({ stack = s, cfg = config.get(), host = X.HOST, project = X.PROJECT, today = X.TODAY }, { iid = 214 })
  local g = s:top().group
  H.wait_for(function()
    return lines(g.members.header.buf)[2]:find("Closed", 1, true) ~= nil
  end)
  keys("<Tab>")
  local win = g.members.content.win
  H.wait_for(function()
    return (lines(vim.api.nvim_win_get_buf(win))[2] or ""):find("YESTERDAY", 1, true) ~= nil
  end)
  eq(g.members.dock, nil) -- no comment box on a closed issue
  keys("i")
  eq(last_note(), "gg.ui: Commenting is closed")
end

T["composer: grows, placeholder, mentions"] = function()
  local cfg = config.get()
  local buf = vim.api.nvim_create_buf(false, true)
  local host_win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 1, col = 1, width = 80, height = 30 })
  local composer = require("gg.ui.components.composer")
  local closed
  local c = composer.open({
    win = host_win,
    width = 60,
    title = "Comment",
    placeholder = "write here",
    keys = cfg.keymaps,
    mentions = function()
      return { { word = "ann" }, { word = "bob", menu = "Bob" } }
    end,
    on_submit = function(_, _, done)
      done(true)
    end,
    on_close = function(posted)
      closed = posted
    end,
  })
  vim.cmd("stopinsert")
  eq(vim.api.nvim_win_get_config(c.win).height, composer.MIN_HEIGHT)
  -- docked at the bottom of the window
  eq(vim.api.nvim_win_get_config(c.win).row, 30 - composer.MIN_HEIGHT - 2)
  local marks = vim.api.nvim_buf_get_extmarks(c.buf, -1, 0, -1, { details = true })
  eq(marks[1][4].virt_text, { { "write here", "GitlabEditPlaceholder" } })
  local many = {}
  for i = 1, 14 do
    many[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(c.buf, 0, -1, false, many)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = c.buf })
  eq(vim.api.nvim_win_get_config(c.win).height, composer.MAX_HEIGHT)
  vim.api.nvim_buf_set_lines(c.buf, 0, -1, false, { "hi @b x" }) -- the cursor after "@b"
  vim.api.nvim_win_set_cursor(c.win, { 1, 5 })
  c:_mention()
  eq(c.last_items, { { word = "bob", menu = "Bob" } })
  keys("<C-s>")
  eq(closed, true)
  vim.api.nvim_win_close(host_win, true)
end

return T
