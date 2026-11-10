-- The screen stack and the detail host: real windows over the issues picker.
local D = require("tests.support.ui_data")
local H = require("tests.helpers")
local config = require("gg.ui.config")
local doc = require("gg.ui.lib.doc")
local host = require("gg.ui.detail.host")
local view = require("gg.ui.issues.view")
local eq = MiniTest.expect.equality

local current
local saved = {}

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { columns = vim.o.columns, lines = vim.o.lines }
      vim.o.columns, vim.o.lines = 170, 40
    end,
    post_case = function()
      if current and not current.shell.stack:is_closed() then
        current.shell.stack:close()
      end
      current = nil
      vim.o.columns, vim.o.lines = saved.columns, saved.lines
      config.setup()
      H.reset()
    end,
  },
})

local function keys(s)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, false, true), "x", false)
end

local function open_picker()
  local fake = H.fake()
  fake:add(D.responses(nil, { ["repeat"] = true }))
  current = view.open({ host = D.HOST, project = D.PROJECT, today = D.TODAY, config = config.get() })
  H.wait_for(function()
    return current.status == "ready" and not current.pending.opened and not current.pending.closed
  end)
  return current
end

local function hidden(win)
  return vim.api.nvim_win_get_config(win).hide == true
end

-- a detail screen with two tabs and a sidebar; records what happened
local function push(v, log)
  local h
  v.shell:push(function(stack)
    h = host.new({
      stack = stack,
      cfg = config.get(),
      name = "test",
      sidebar = true,
      tabs = { { key = "a", label = "One" }, { key = "b", label = "Two" } },
      on_refresh = function()
        table.insert(log, "refresh")
      end,
      on_tab = function(key)
        table.insert(log, "tab:" .. key)
      end,
    })
    h.screen.teardown = function()
      table.insert(log, "teardown")
    end
    return h.screen
  end)
  return h
end

T["push hides the picker, q comes back with the selection intact"] = function()
  local v = open_picker()
  local suspended = 0
  v.suspend = function()
    suspended = suspended + 1
  end
  keys("jj")
  local sel = v.selected_iid
  local log = {}
  local h = push(v, log)
  eq(v.shell.stack:depth(), 2)
  eq(suspended, 1)
  eq(hidden(v.table_float.win), true)
  eq(hidden(v.filter_float.win), true)
  eq(vim.api.nvim_get_current_win(), h.content_float.win)
  -- the picker did not close although focus left it
  H.flush(30)
  eq(v.closed, false)
  keys("q")
  eq(v.shell.stack:depth(), 1)
  eq(log, { "teardown" })
  eq(vim.api.nvim_win_is_valid(h.content_float.win), false)
  eq(hidden(v.table_float.win), false)
  eq(vim.api.nvim_get_current_win(), v.table_float.win)
  eq(v.selected_iid, sel)
end

T["Q closes everything and returns to the start window"] = function()
  local start = vim.api.nvim_get_current_win()
  local v = open_picker()
  local h = push(v, {})
  keys("Q")
  eq(v.closed, true)
  eq(v.shell.stack:is_closed(), true)
  eq(vim.api.nvim_win_is_valid(h.content_float.win), false)
  eq(vim.api.nvim_win_is_valid(v.table_float.win), false)
  eq(vim.api.nvim_get_current_win(), start)
end

T["closing a detail window from outside closes the stack"] = function()
  local v = open_picker()
  local h = push(v, {})
  vim.api.nvim_win_close(h.content_float.win, true)
  H.wait_for(function()
    return v.closed
  end)
  eq(v.shell.stack:is_closed(), true)
end

T["host: tabs swap buffers, R reloads, the sidebar follows the width"] = function()
  local v = open_picker()
  local log = {}
  local h = push(v, log)
  eq(h:has_sidebar(), true)
  eq(h:sidebar_width(), 32)
  local title = vim.api.nvim_win_get_config(h.content_float.win).title
  eq(title[2], { " One ", "GitlabTabActive" })
  local d = doc.new()
  d:text("hello", "X", { kind = "greeting" })
  d:text("world")
  h:set_content("a", d)
  eq(vim.api.nvim_buf_get_lines(h:buf("a"), 0, -1, false), { "hello", "world" })
  eq(h:current(), { kind = "greeting" })
  keys("<Tab>")
  eq(h.active, "b")
  eq(vim.api.nvim_win_get_buf(h.content_float.win), h:buf("b"))
  keys("<S-Tab>")
  eq(h.active, "a")
  keys("R")
  eq(log, { "tab:b", "tab:a", "refresh" })
  -- the header grows with its content
  local hd = doc.new()
  for i = 1, 5 do
    hd:text("line " .. i)
  end
  h:set_header(hd, { { " crumb ", "X" } })
  eq(vim.api.nvim_win_get_height(h.header_float.win), 5)
  eq(vim.api.nvim_win_get_config(h.content_float.win).row, 7)
  -- narrow: the sidebar goes, wide again: it comes back
  vim.o.columns = 90
  vim.api.nvim_exec_autocmds("VimResized", {})
  eq(h:has_sidebar(), false)
  eq(h.group:is_closed(), false)
  vim.o.columns = 170
  vim.api.nvim_exec_autocmds("VimResized", {})
  eq(h:has_sidebar(), true)
  keys("q")
  eq(vim.api.nvim_buf_is_valid(h.bufs.a), false)
end

T["a hidden picker stays hidden across a resize"] = function()
  local v = open_picker()
  push(v, {})
  vim.o.lines = 30
  vim.api.nvim_exec_autocmds("VimResized", {})
  eq(hidden(v.table_float.win), true)
  keys("q")
  eq(hidden(v.table_float.win), false)
  eq(vim.api.nvim_win_get_config(v.table_float.win).height, 30 - 1 - 3 - 2)
end

return T
