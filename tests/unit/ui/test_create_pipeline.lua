-- Run pipeline: the ref field, the variables editor, validation, submit.
local H = require("tests.helpers")
local P = require("tests.support.create_data")
local X = require("tests.support.detail_data")
local def = require("gg.ui.create.defs.pipeline")
local eq = MiniTest.expect.equality

local retry_ms = def.tuning.retry_ms

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      P.pre_case()
      def.tuning.retry_ms = 10
    end,
    post_case = function()
      def.tuning.retry_ms = retry_ms
      P.post_case()
    end,
  },
})

local API = "/api/v4/projects/" .. X.ENC
local BRANCHES = API .. "/repository/branches"

local function branch(name, default)
  return { name = name, default = default or false, protected = false, merged = false, commit = { id = "1a2b3c4d5e6f", title = "tidy up " .. name, committed_date = X.NOW } }
end

local function get_branch(name)
  return { ["repeat"] = true, request = { method = "GET", path = BRANCHES .. "/" .. name }, response = { body = branch(name, name == "main") } }
end

local function config(list, opts)
  return {
    ["repeat"] = opts and opts["repeat"],
    request = { operation = "PipelineConfigVariables" },
    response = { body = { data = { project = { ciConfigVariables = list } } } },
  }
end

local TWO = {
  { key = "DEPLOY_ENVIRONMENT", value = "staging", description = "Where to", valueOptions = vim.NIL },
  { key = "DRY_RUN", value = "true", description = vim.NIL, valueOptions = vim.NIL },
}

local function open(responses, preset)
  local p, s, fake = P.open("pipeline", preset or { ref = "main" }, responses)
  H.wait_for(function()
    return p:field("ref") ~= nil
  end)
  return p, s, fake
end

local function types(p)
  return vim.tbl_filter(function(t)
    return t == "var" or t == "file"
  end, P.virt(p.body_float.buf))
end

T["opens with the ref, its commit, and the declared variables"] = function()
  local p = open({ get_branch("main"), config(TWO) })
  local m = p.group.members
  H.wait_for(function()
    return #P.lines(m.body.buf) == 2
  end)
  eq(P.title(m.title.win), " ▶ Run pipeline ")
  eq(vim.api.nvim_win_get_config(m.title.win).title[1][2], "GitlabCreatePipeline")
  eq(P.lines(m.title.buf), { "Run pipeline for ⎇ main" })
  eq(vim.bo[m.title.buf].modifiable, false)
  eq(P.title(m.field_ref.win), " [gB] Branch or tag ")
  eq(P.lines(m.field_ref.buf), { "⎇ main  1a2b3c4d  tidy up main" })
  -- one field: as wide as the popup
  eq(vim.api.nvim_win_get_config(m.field_ref.win).width, vim.api.nvim_win_get_config(m.body.win).width)
  eq(P.lines(m.body.buf), { "DEPLOY_ENVIRONMENT = staging", "DRY_RUN = true" })
  eq(P.title(m.body.win):find(" Variables · 2 ─", 1, true) ~= nil, true)
  eq(P.footer(m.body.win):find(" [a] Add • [dd] Remove • [t] Var ⇄ file • [<Esc><Esc>] Cancel ", 1, true), 1)
  eq(P.footer(m.body.win):find(" [<C-s>] Run ─", 1, true) ~= nil, true)
  eq(vim.wo[m.body.win].winbar, "%#GitlabColumnHeader# Key = Value%=Type ")
  eq(types(p), { "var", "var" })
  eq(#vim.tbl_filter(function(t)
    return t == "  default from .gitlab-ci.yml"
  end, P.virt(m.body.buf)), 2)
  eq(p:dirty(), false)
  eq(vim.api.nvim_get_current_win(), m.body.win)
  -- Tab skips the read-only title
  P.keys("<Tab>")
  eq(vim.api.nvim_get_current_win(), m.field_ref.win)
  P.keys("<Tab>")
  eq(vim.api.nvim_get_current_win(), m.body.win)
end

T["the CI variables are asked for again while GitLab is still reading them"] = function()
  local p, _, fake = open({ get_branch("main"), config(vim.NIL), config(vim.NIL), config(TWO) })
  H.wait_for(function()
    return #P.lines(p.body_float.buf) == 2
  end)
  eq(#vim.tbl_filter(function(r)
    return r.operation == "PipelineConfigVariables"
  end, fake:requests()), 3)
end

T["without declared variables the editor starts empty"] = function()
  local p = open({ get_branch("main"), config({}) })
  H.flush(30)
  eq(P.lines(p.body_float.buf), { "" })
  eq(P.title(p.body_float.win):find(" Variables · 0 ─", 1, true) ~= nil, true)
  eq(types(p), {})
end

T["a branch that is not on GitLab falls back to the default branch"] = function()
  local p = open({
    { request = { method = "GET", path = BRANCHES .. "/local-only" }, response = { status = 404, body = { message = "404 Branch Not Found" } } },
    X.replay("graphql/projects/get.json", { operation = "ProjectGet" }),
    get_branch("main"),
    config({}, { ["repeat"] = true }),
  }, { ref = "local-only" })
  eq(p:field("ref"), "main")
  H.wait_for(function()
    return P.lines(p.group.members.field_ref.buf)[1] == "⎇ main  1a2b3c4d  tidy up main"
  end)
  eq(P.lines(p.title_float.buf), { "Run pipeline for ⎇ main" })
end

T["a adds a variable, t toggles its type, the type stays with its line"] = function()
  local p = open({ get_branch("main"), config({}) })
  local buf, win = p.body_float.buf, p.body_float.win
  H.flush(20)
  P.keys("a")
  eq(P.lines(buf), { "‹KEY› = ‹value›" })
  -- the key placeholder is selected: typing replaces it
  H.wait_for(function()
    return vim.api.nvim_get_mode().mode == "s"
  end)
  P.keys("CERT")
  vim.cmd("stopinsert")
  P.keys("<C-n>")
  H.wait_for(function()
    return vim.api.nvim_get_mode().mode == "s"
  end)
  P.keys("abc")
  vim.cmd("stopinsert")
  eq(P.lines(buf), { "CERT = abc" })
  eq(P.title(win):find(" Variables · 1 ─", 1, true) ~= nil, true)
  eq(types(p), { "var" })
  P.keys("t")
  eq(types(p), { "file" })
  -- a second one below; the first keeps its type
  P.keys("a")
  H.wait_for(function()
    return vim.api.nvim_get_mode().mode == "s"
  end)
  P.keys("DEBUG")
  vim.cmd("stopinsert")
  eq(P.lines(buf), { "CERT = abc", "DEBUG = ‹value›" })
  eq(p.data.editor:line_types(), { "file", "var" })
  -- a line inserted above moves the type with its line
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "FIRST = 1" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  eq(p.data.editor:line_types(), { "var", "file", "var" })
  -- dd removes the line and its type
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  P.keys("dd")
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  eq(P.lines(buf), { "FIRST = 1", "DEBUG = ‹value›" })
  eq(p.data.editor:line_types(), { "var", "var" })
  eq(P.title(win):find(" Variables · 2 ─", 1, true) ~= nil, true)
  P.keys("t")
  eq(p.data.editor:line_types(), { "var", "file" })
end

T["bad lines get a diagnostic and block the run"] = function()
  local p, _, fake = open({ get_branch("main"), config({}) })
  local buf = p.body_float.buf
  H.flush(20)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "OK = 1", "1BAD = x", "OK = 2" })
  local before = #fake:requests()
  P.keys("<C-s>")
  eq(#fake:requests(), before)
  local d = vim.diagnostic.get(buf, { namespace = p.diag_ns })
  eq(vim.tbl_map(function(x)
    return { x.lnum, x.message }
  end, d), {
    { 1, 'invalid key "1BAD": letters, digits and _ only, not starting with a digit' },
    { 2, "OK is already set on line 1" },
  })
  eq(P.footer(p.body_float.win):find(" 2 variables need fixing ─", 1, true) ~= nil, true)
  eq(p.state, "error")
  -- one problem: the border names it
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "OK = 1", "nothing here" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  eq(#vim.diagnostic.get(buf, { namespace = p.diag_ns }), 0)
  P.keys("<C-s>")
  eq(P.footer(p.body_float.win):find(" Line 2: expected KEY = value ─", 1, true) ~= nil, true)
end

T["<C-s> runs the pipeline with its variables and opens it"] = function()
  local p, s, fake = open({
    get_branch("main"),
    config(TWO),
    {
      request = { method = "POST", path = API .. "/pipeline" },
      response = { status = 201, delay = 20, body = { id = X.PIPELINE_ID, iid = 21, status = "pending", ref = "main", sha = "a1f3c9e0a1f3c9e0", source = "api", web_url = "https://gitlab.example.com/infra/ops/-/pipelines/4821" } },
    },
    X.pipeline_graph({}, { ["repeat"] = true }),
  })
  local buf, win = p.body_float.buf, p.body_float.win
  H.wait_for(function()
    return #P.lines(buf) == 2
  end)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "DRY_RUN = false", "", "KUBECONFIG = apiVersion: v1" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  -- an edited default no longer says it is one
  eq(#vim.tbl_filter(function(t)
    return t == "  default from .gitlab-ci.yml"
  end, P.virt(buf)), 1)
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  P.keys("t")
  P.keys("<C-s>")
  eq(P.footer(win):find(" running… ─", 1, true) ~= nil, true)
  H.wait_for(function()
    return p.closed and s:depth() == 2 and s:top().group.members.header ~= nil
  end)
  local post
  for _, r in ipairs(fake:requests()) do
    if r.method == "POST" and r.path == API .. "/pipeline" then
      post = r.json
    end
  end
  eq(post, {
    ref = "main",
    variables = {
      { key = "DEPLOY_ENVIRONMENT", value = "staging", variable_type = "env_var" },
      { key = "DRY_RUN", value = "false", variable_type = "env_var" },
      { key = "KUBECONFIG", value = "apiVersion: v1", variable_type = "file" },
    },
  })
  eq(s.screens[1].dirty, { pipeline = true })
end

T["gB lists branches and tags; a tag becomes the ref"] = function()
  local p = open({
    get_branch("main"),
    config({}, { ["repeat"] = true }),
    { ["repeat"] = true, request = { method = "GET", path = BRANCHES }, response = { body = { branch("develop"), branch("main", true) } } },
    {
      ["repeat"] = true,
      request = { method = "GET", path = API .. "/repository/tags" },
      response = { body = { { name = "v1.2.0", target = "9f8e7d6c5b4a", protected = true, commit = { id = "9f8e7d6c5b4a", title = "Release 1.2.0" } } } },
    },
  })
  local m = p.group.members
  P.keys("gB")
  local list
  H.wait_for(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "gg_ui_ref_list" then
        list = vim.api.nvim_win_get_buf(w)
      end
    end
    return list ~= nil and #P.lines(list) == 3
  end)
  eq(P.title(vim.api.nvim_get_current_win()), " Branch or tag ")
  eq(P.lines(list), {
    " ⎇ main  1a2b3c4d  tidy up main",
    " ⎇ develop  1a2b3c4d  tidy up develop",
    " ◆ v1.2.0  9f8e7d6c  Release 1.2.0",
  })
  P.keys("<C-p>") -- wraps to the tag
  P.keys("<CR>")
  eq(p:field("ref"), "v1.2.0")
  eq(P.lines(m.field_ref.buf), { "⎇ v1.2.0  9f8e7d6c  Release 1.2.0" })
  eq(P.lines(m.title.buf), { "Run pipeline for ⎇ v1.2.0" })
  eq(p:dirty(), true)
end

T["an API error stays in the popup"] = function()
  local p, s = open({
    get_branch("main"),
    config({}),
    { request = { method = "POST", path = API .. "/pipeline" }, response = { status = 400, body = { message = { base = { "Reference not found" } } } } },
  })
  H.flush(20)
  P.keys("<C-s>")
  H.wait_for(function()
    return p.state == "error"
  end)
  eq({ p.closed, s:depth() }, { false, 2 })
  eq(P.footer(p.body_float.win):find(" base Reference not found ─", 1, true) ~= nil, true)
  eq(vim.bo[p.body_float.buf].modifiable, true)
end

return T
