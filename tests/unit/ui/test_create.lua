-- Creating from an issue: a branch (gb) and a merge request (gP, the form).
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

local BRANCHES = "/api/v4/projects/" .. X.ENC .. "/repository/branches"

local function branch(name, default)
  return { name = name, default = default or false, protected = default or false, merged = false, commit = { id = "abc", title = "x", committed_date = X.NOW } }
end

local function open(responses)
  local fake = H.fake()
  fake:add(responses)
  s = stack.new()
  detail.issue({ stack = s, cfg = config.get(), host = X.HOST, project = X.PROJECT, today = X.TODAY }, { iid = 214 })
  local g = s:top().group
  H.wait_for(function()
    local side = table.concat(lines(g.members.sidebar.buf), "\n")
    return lines(g.members.content.buf)[2] == " Rotate the credentials of the state backend." and not side:find("Loading", 1, true)
  end)
  return g, fake
end

T["gb creates a branch named after the issue from the branch picked"] = function()
  local base = X.issue_responses({ branches = {} })
  local g, fake = open(vim.list_extend(base, {
    { request = { method = "GET", path = BRANCHES }, response = { body = { branch("dev"), branch("main", true) } } },
    {
      request = { method = "POST", path = BRANCHES, query = { branch = "214-rotate-terraform-state-backend-credentials", ref = "main" } },
      response = { status = 201, body = branch("214-rotate-terraform-state-backend-credentials") },
    },
  }))
  local offered, default
  vim.ui.select = function(items, opts, cb)
    offered = vim.tbl_map(opts.format_item, items)
    cb(items[1])
  end
  vim.ui.input = function(opts, cb)
    default = opts.default
    cb(opts.default)
  end
  keys("gb")
  H.wait_for(function()
    return table.concat(lines(g.members.sidebar.buf), "\n"):find("⎇ 214-rotate-terraform-state", 1, true) ~= nil
  end)
  eq(offered, { "main  (default)", "dev" }) -- the default branch first
  eq(default, "214-rotate-terraform-state-backend-credentials")
  eq(notes[#notes][1], "gg.ui: Branch created: 214-rotate-terraform-state-backend-credentials (from main)")
  -- a second branch is refused
  keys("gb")
  eq(notes[#notes][1], "gg.ui: A branch is already linked: 214-rotate-terraform-state-backend-credentials")
  _ = fake
end

T["gP opens the new merge request form; <C-s> creates it and shows it"] = function()
  local project = X.replay("graphql/projects/get.json", { operation = "ProjectGet" }, { ["repeat"] = true })
  project.response.body.data.project.fullPath = X.PROJECT
  local g, fake = open(vim.list_extend(X.issue_responses(), {
    project,
    X.members(),
    {
      request = {
        method = "POST",
        path = "/api/v4/projects/" .. X.ENC .. "/merge_requests",
        body_contains = { source_branch = "214-rotate-credentials", target_branch = "main", title = "Rotate the keys" },
      },
      response = { status = 201, body = X.rest_mr(89, "Rotate the keys") },
    },
  }))
  keys("gP")
  H.wait_for(function()
    return s:depth() == 2 and #lines(s:top().group.members.content.buf) > 5
  end)
  local form = s:top().group.members
  H.wait_for(function()
    local l = table.concat(lines(form.content.buf), "\n")
    return l:find("⎇ main", 1, true) ~= nil and l:find("@user-1", 1, true) ~= nil
  end)
  local l = lines(form.content.buf)
  eq(vim.startswith(l[2], " Source     ⎇ 214-rotate-credentials"), true)
  eq(vim.startswith(l[3], " Target     ⎇ main"), true)
  eq(l[4], ' Title      Draft: Resolve "Rotate Terraform state backend credentials"')
  eq(l[5], " Assignees  @user-1")
  eq(l[6], " Draft      yes")
  eq(l[9], " Closes #214")
  local foot = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(form.content.win).footer))
  eq(foot, " [i] Edit • [<C-s>] Create • [q] Discard ")
  -- the title, in its overlay (draft follows the prefix)
  vim.api.nvim_win_set_cursor(form.content.win, { 4, 0 })
  keys("i")
  H.wait_for(function()
    return vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).zindex == 200
  end)
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Rotate the keys" })
  keys("<C-s>")
  eq(lines(form.content.buf)[4], " Title      Rotate the keys")
  eq(lines(form.content.buf)[6], " Draft      no")
  keys("<C-s>") -- create
  H.wait_for(function()
    return s:depth() == 2 and lines(s:top().group.members.header.buf)[2]:find("!89", 1, true) ~= nil
  end)
  local post
  for _, r in ipairs(fake:requests()) do
    if r.method == "POST" and r.path == "/api/v4/projects/" .. X.ENC .. "/merge_requests" then
      post = r.json
    end
  end
  eq({ post.description, post.assignee_ids }, { "Closes #214", { 1 } })
  _ = g
end

return T
