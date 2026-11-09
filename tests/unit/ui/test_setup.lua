-- gg.ui: config, project resolution, highlights, the :Gitlab command.
local H = require("tests.helpers")
local config = require("gg.ui.config")
local highlights = require("gg.ui.highlights")
local project = require("gg.ui.project")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.setup()
      H.reset()
    end,
  },
})

T["config: defaults and merge"] = function()
  local c = config.get()
  eq({ c.limit, c.page_size, c.keymaps.next_tab, c.keymaps.next_page, c.keymaps.close }, { 2000, 50, "L", "P", "q" })
  eq(type(c.on_inspect_issue), "function")
  eq({ config.setup({ page_size = 10, keymaps = { close = false, refresh = "r" } }) }, { true, nil })
  c = config.get()
  eq({ c.page_size, c.keymaps.close, c.keymaps.refresh, c.keymaps.next_tab }, { 10, false, "r", "L" })
end

T["config: validation keeps the previous options"] = function()
  config.setup({ page_size = 7 })
  local bad = {
    { { bogus = 1 }, "ui.bogus" },
    { { limit = 0 }, "ui.limit" },
    { { page_size = 1.5 }, "ui.page_size" },
    { { keymaps = { nope = "x" } }, "ui.keymaps.nope" },
    { { keymaps = { close = true } }, "ui.keymaps.close" },
    { { keymaps = { close = "" } }, "ui.keymaps.close" },
    { { order = { top = "x" } }, "ui.order.top" },
    { { order = { other = function() end } }, "ui.order.other" },
    { { on_inspect_issue = 1 }, "ui.on_inspect_issue" },
    { "string", "ui.opts" },
  }
  for _, case in ipairs(bad) do
    local ok, err = config.setup(case[1])
    eq(ok, false)
    eq(err.kind, "validation")
    eq(vim.startswith(err.message, case[2]), true)
  end
  eq(config.get().page_size, 7)
end

T["project.parse: group/project, host/group/project, URLs"] = function()
  local one = { ["gitlab.example.com"] = { aliases = { "ssh.example.com" } } }
  eq(project.parse("infra/ops", one), { host = "gitlab.example.com", project = "infra/ops" })
  eq(project.parse("/infra/sub/ops.git/", one), { host = "gitlab.example.com", project = "infra/sub/ops" })
  eq(project.parse("gitlab.example.com/infra/ops", one), { host = "gitlab.example.com", project = "infra/ops" })
  eq(project.parse("ssh.example.com/infra/ops", one), { host = "gitlab.example.com", project = "infra/ops" })
  local two = { ["gitlab.example.com"] = {}, ["gl.example.org"] = {} }
  eq(project.parse("gl.example.org/a/b", two), { host = "gl.example.org", project = "a/b" })
  local _, err = project.parse("a/b", two)
  eq(err.message:find("several hosts", 1, true) ~= nil, true)
  _, err = project.parse("a/b", {})
  eq(err.message:find("no GitLab host is configured", 1, true) ~= nil, true)
  _, err = project.parse("justone", one)
  eq(err.kind, "validation")
  _, err = project.parse("", one)
  eq(err.kind, "validation")
end

T["project.parse: remote URLs need a configured host"] = function()
  H.fake()
  eq(project.parse("git@gitlab.example.com:infra/ops.git"), { host = "gitlab.example.com", project = "infra/ops" })
  eq(project.parse("https://gitlab.example.com/infra/ops"), { host = "gitlab.example.com", project = "infra/ops" })
  local _, err = project.parse("git@other.example.net:infra/ops.git")
  eq(err.message:find("not configured", 1, true) ~= nil, true)
end

T["project.resolve: from the git remote of a directory (async)"] = function()
  H.fake()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.system({ "git", "-C", dir, "init", "-q" })
  vim.fn.system({ "git", "-C", dir, "remote", "add", "origin", "git@gitlab.example.com:infra/ops.git" })
  local target, err = H.await(project.resolve({ cwd = dir }), 5000)
  eq(err, nil)
  eq(target, { host = "gitlab.example.com", project = "infra/ops" })
  -- no remote
  local empty = vim.fn.tempname()
  vim.fn.mkdir(empty, "p")
  vim.fn.system({ "git", "-C", empty, "init", "-q" })
  local _, err2 = H.await(project.resolve({ cwd = empty }), 5000)
  eq(err2.message:find("no git remote", 1, true) ~= nil, true)
  -- an explicit argument wins and needs no git
  eq(H.await(project.resolve({ arg = "a/b", cwd = empty })), { host = "gitlab.example.com", project = "a/b" })
  vim.fn.delete(dir, "rf")
  vim.fn.delete(empty, "rf")
end

T["highlights: default links, label groups, re-defined on ColorScheme"] = function()
  highlights.setup()
  for _, pair in ipairs(highlights.LINKS) do
    eq(vim.api.nvim_get_hl(0, { name = pair[1] }).link, pair[2])
  end
  eq(vim.api.nvim_get_hl(0, { name = "GitlabHintKey" }).bold, true)
  eq(highlights.label("#FF9E64"), "GitlabLabel_ff9e64")
  eq(vim.api.nvim_get_hl(0, { name = "GitlabLabel_ff9e64" }).fg, 0xff9e64)
  eq(highlights.label("#abc"), "GitlabLabel_aabbcc")
  eq(highlights.label(nil), "GitlabLabelFallback")
  eq(highlights.label("red"), "GitlabLabelFallback")
  -- user overrides win (default = true)
  vim.api.nvim_set_hl(0, "GitlabIid", { fg = "#010203" })
  highlights.define()
  eq(vim.api.nvim_get_hl(0, { name = "GitlabIid" }).fg, 0x010203)
  vim.cmd("highlight clear")
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  eq(vim.api.nvim_get_hl(0, { name = "GitlabIid" }).link, "Comment")
end

T[":Gitlab is registered by plugin/gg.lua"] = function()
  vim.g.loaded_gg_ui = nil
  vim.cmd("source " .. H.path("plugin/gg.lua"))
  local cmd = vim.api.nvim_get_commands({}).Gitlab
  eq(cmd ~= nil, true)
  eq(cmd.nargs, "?")
end

return T
