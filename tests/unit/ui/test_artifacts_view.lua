-- The artifacts view end to end: real windows, fake backend.
local D = require("tests.support.artifact_data")
local H = require("tests.helpers")
local config = require("gg.ui.config")
local view = require("gg.ui.artifacts.view")
local eq = MiniTest.expect.equality

local current -- the view under test (its picker is closed after each case)
local saved = {}
local tmp_root

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { columns = vim.o.columns, lines = vim.o.lines, notify = vim.notify, input = vim.ui.input, cache = view.CACHE_ROOT }
      vim.o.columns, vim.o.lines = 170, 40
      tmp_root = vim.fn.tempname()
      view.CACHE_ROOT = tmp_root .. "/cache"
    end,
    post_case = function()
      if current then
        pcall(function()
          current.shell:close()
        end)
        current = nil
      end
      vim.cmd("silent! tabonly!")
      vim.notify, vim.ui.input = saved.notify, saved.input
      view.CACHE_ROOT = saved.cache
      vim.o.columns, vim.o.lines = saved.columns, saved.lines
      vim.fn.delete(tmp_root, "rf")
      config.setup()
      H.reset()
    end,
  },
})

local function open(cfg, extra)
  local fake = H.fake()
  fake:add(extra or {})
  fake:add(D.responses(os.time()))
  local c = vim.tbl_deep_extend("force", config.get(), { artifacts = { download_dir = tmp_root .. "/dl" } }, cfg or {})
  current = view.open({ host = D.HOST, project = D.PROJECT, config = c })
  return current, fake
end

local function ready(v)
  H.wait_for(function()
    return v.status == "ready" and v.ctx.default_branch ~= nil
  end)
  return v
end

local function lines(v)
  return vim.api.nvim_buf_get_lines(v.shell.table_float.buf, 0, -1, false)
end

local function keys(s)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, false, true), "x", false)
end

local function cursor(v)
  return vim.api.nvim_win_get_cursor(v.shell.table_float.win)[1]
end

-- the line number of node `id`
local function lnum_of(v, id)
  for lnum, info in pairs(v.rendered.rows) do
    if info.node and info.kind ~= "status" and info.node.id == id then
      return lnum
    end
  end
end

local function goto_node(v, id)
  local lnum = lnum_of(v, id)
  assert(lnum, "no row for " .. id)
  vim.api.nvim_set_current_win(v.shell.table_float.win)
  v.list:select(lnum)
  eq(v.selected_id, id)
end

local function text(v)
  return table.concat(lines(v), "\n")
end

local function footer_text(v)
  local f = vim.api.nvim_win_get_config(v.shell.table_float.win).footer
  return table.concat(vim.tbl_map(function(c)
    return c[1]
  end, f))
end

local function notices()
  local got = {}
  vim.notify = function(msg, level)
    table.insert(got, { msg, level })
  end
  return got
end

-- answer the next y/N prompts in order; returns the questions asked
local function answers(list)
  local asked = {}
  vim.ui.input = function(opts, cb)
    table.insert(asked, opts.prompt)
    cb(table.remove(list, 1))
  end
  return asked
end

T["opens on gg.ui.open; newest and default-branch pipelines open; footer"] = function()
  local fake = H.fake()
  fake:add(D.responses(os.time()))
  current = require("gg.ui").open({ host = D.HOST, project = D.PROJECT, view = "artifacts" })
  ready(current)
  eq(current.name, "artifacts")
  eq(vim.bo[current.shell.table_float.buf].filetype, "gg_ui_artifacts")
  local s = text(current)
  eq(s:find("Name", 1, true) ~= nil, true)
  eq(s:find("▾ ✗ #4819  feat/oci-edge-lb", 1, true) ~= nil, true)
  eq(s:find("▾ ✓ #4812  main", 1, true) ~= nil, true)
  eq(s:find("├── ▸ build:package  › artifacts.zip", 1, true) ~= nil, true)
  eq(s:find("▸ ▸ #4817", 1, true) ~= nil, true)
  eq(s:find("#4806", 1, true), nil) -- expired only
  eq(footer_text(current), " [d] Download • [o] Open in buffer • [y] Copy path ")
  -- no tabs line: blank, header, rule, then the first pipeline
  eq(lines(current)[2]:match("^%s*Name"), "  Name")
  eq(current.rendered.rows[4].node.id, "p:4819")
  -- only node rows are selectable; the cursor starts on the first
  eq(cursor(current), 4)
  -- `L` / `H` do nothing here
  keys("L")
  eq(current.shell.active, current)
end

T["<CR> on an archive lists it from GitLab's tree; the cursor stays"] = function()
  local v, fake = open()
  ready(v)
  goto_node(v, "a:91022:archive")
  local before = cursor(v)
  keys("<CR>")
  H.wait_for(function()
    return v.listing[91022] and v.listing[91022].status == "listed"
  end)
  eq(fake:last().query.recursive, "true")
  eq(cursor(v), before)
  eq(v.selected_id, "a:91022:archive")
  local s = text(v)
  eq(s:find("│   ├── ▸ dist/  2 files", 1, true) ~= nil, true)
  eq(s:find("│   ├── ▸ reports/  2 files", 1, true) ~= nil, true)
  eq(s:find("│   ╰── VERSION", 1, true) ~= nil, true)
  -- l opens a folder, h closes it again from inside and moves to it
  goto_node(v, "d:91022:reports/")
  keys("l")
  goto_node(v, "f:91022:reports/terraform-docs.md")
  keys("h")
  eq(v.selected_id, "d:91022:reports/")
  eq(lnum_of(v, "f:91022:reports/terraform-docs.md"), nil)
  -- zR opens every listed node, zM closes everything
  keys("zR")
  eq(lnum_of(v, "f:91022:modules/edge-lb/main.tf") ~= nil, true)
  eq(lnum_of(v, "a:91024:archive") ~= nil, true)
  eq(v.listing[91024], nil) -- zR does not list archives
  keys("zM")
  eq(lnum_of(v, "a:91022:archive"), nil)
end

T["an archive GitLab cannot list is downloaded to the cache and read"] = function()
  local v = open(nil, D.zip_responses())
  ready(v)
  goto_node(v, "p:4815")
  keys("<CR>")
  goto_node(v, "a:91024:archive")
  keys("<CR>")
  H.wait_for(function()
    return v.listing[91024] and v.listing[91024].status ~= "loading"
  end)
  eq(v.listing[91024].status, "listed")
  eq(vim.fn.filereadable(v:_cache_path(91024)), 1)
  local s = text(v)
  eq(s:find("│   ├── ▸ dist/  1 file", 1, true) ~= nil, true)
  eq(s:find("│   ├── build.log", 1, true) ~= nil, true)
end

T["a big archive asks first; no leaves it closed"] = function()
  local v = open({ artifacts = { confirm_size = 1024 } }, D.zip_responses())
  ready(v)
  local asked = answers({ "n" })
  goto_node(v, "p:4815")
  keys("<CR>")
  goto_node(v, "a:91024:archive")
  keys("<CR>")
  H.wait_for(function()
    return #asked > 0
  end)
  eq(asked[1], "Download 3.2 MB to browse? [y/N]: ")
  H.wait_for(function()
    return v.listing[91024] == nil
  end)
  eq(v.open["a:91024:archive"], nil)
end

T["a failed listing shows an error line; R retries"] = function()
  local v, fake = open(nil, {
    { request = { method = "GET", path = D.REST .. "91060/artifacts/tree" }, response = { status = 404, body = { message = "404 Not Found" } } },
    { request = { method = "GET", path = D.REST .. "91060/artifacts" }, response = { status = 404, body = { message = "404 Not Found" } } },
  })
  ready(v)
  goto_node(v, "p:4808")
  keys("<CR>")
  goto_node(v, "a:91060:archive")
  keys("<CR>")
  H.wait_for(function()
    return v.listing[91060] and v.listing[91060].status == "error"
  end)
  local s = text(v)
  eq(s:find("    ╰── ✗ ", 1, true) ~= nil, true)
  eq(s:find("· [R] retry", 1, true) ~= nil, true)
  fake:add({ request = { method = "GET", path = D.REST .. "91060/artifacts/tree" }, response = { status = 200, body = { { name = "drift-report.md", path = "drift-report.md", type = "file", size = 47104 } } } })
  keys("R")
  H.wait_for(function()
    return v.listing[91060] and v.listing[91060].status == "listed"
  end)
  eq(text(v):find("╰── drift-report.md", 1, true) ~= nil, true)
end

T["d downloads a file, a report and a folder below download_dir"] = function()
  local v = open()
  ready(v)
  local got = notices()
  goto_node(v, "a:91022:archive")
  keys("<CR>")
  H.wait_for(function()
    return v.listing[91022] and v.listing[91022].status == "listed"
  end)
  goto_node(v, "d:91022:reports/")
  keys("l")
  goto_node(v, "f:91022:reports/terraform-docs.md")
  keys("d")
  local out = tmp_root .. "/dl/gitlab/infra-automation/4812/reports/terraform-docs.md"
  H.wait_for(function()
    return #got > 0
  end)
  eq(H.read(out), "# Terraform docs\n\n| Name | Type |\n")
  eq(got[1][1]:match("^Downloaded terraform%-docs%.md → .*/4812/reports/$") ~= nil, true)
  goto_node(v, "a:91020:dotenv")
  keys("d")
  H.wait_for(function()
    return #got > 1
  end)
  eq(H.read(tmp_root .. "/dl/gitlab/infra-automation/4812/build_vars/build.env"), "VERSION=1.4.2\n")
end

T["o opens a text file read-only in a new tab and closes the picker"] = function()
  local v = open()
  ready(v)
  goto_node(v, "a:91022:archive")
  keys("<CR>")
  H.wait_for(function()
    return v.listing[91022] and v.listing[91022].status == "listed"
  end)
  goto_node(v, "d:91022:reports/")
  keys("l")
  goto_node(v, "f:91022:reports/terraform-docs.md")
  local tabs = #vim.api.nvim_list_tabpages()
  keys("o")
  H.wait_for(function()
    return #vim.api.nvim_list_tabpages() > tabs
  end)
  eq(v.closed, true)
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.api.nvim_buf_get_name(buf), "gitlab://artifacts/91022/reports/terraform-docs.md")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "# Terraform docs", "", "| Name | Type |" })
  eq({ vim.bo[buf].modifiable, vim.bo[buf].readonly, vim.bo[buf].buftype, vim.bo[buf].filetype }, { false, true, "nofile", "markdown" })
end

T["o on a compressed report offers d; vsplit opens beside"] = function()
  local v = open({ artifacts = { open = "vsplit" } })
  ready(v)
  local asked = answers({ "n" })
  goto_node(v, "p:4815")
  keys("<CR>")
  goto_node(v, "a:91031:junit")
  keys("o")
  H.wait_for(function()
    return #asked > 0
  end)
  eq(asked[1], "junit.xml.gz is compressed. Download it instead? [y/N]: ")
  eq(v.closed, false)
  local wins = #vim.api.nvim_tabpage_list_wins(0)
  goto_node(v, "a:91020:dotenv")
  keys("o")
  H.wait_for(function()
    return vim.api.nvim_buf_get_name(0):find("gitlab://artifacts/91020/build.env", 1, true) ~= nil
  end)
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "VERSION=1.4.2" })
  eq(#vim.api.nvim_tabpage_list_wins(0) >= 2, true)
  eq(wins > 0, true)
end

T["y and Y copy the inner path and the web URL"] = function()
  local v = open()
  ready(v)
  notices()
  goto_node(v, "a:91022:archive")
  keys("y")
  eq(vim.fn.getreg('"'), "artifacts.zip")
  keys("Y")
  eq(vim.fn.getreg('"'), "https://gitlab.example.com/my-group/infra-automation/-/jobs/91022/artifacts/browse")
  keys("<CR>")
  H.wait_for(function()
    return v.listing[91022] and v.listing[91022].status == "listed"
  end)
  goto_node(v, "f:91022:build.log")
  keys("y")
  eq(vim.fn.getreg('"'), "build.log")
  keys("Y")
  eq(vim.fn.getreg('"'), "https://gitlab.example.com/my-group/infra-automation/-/jobs/91022/artifacts/file/build.log")
  goto_node(v, "a:91020:dotenv")
  keys("Y")
  eq(vim.fn.getreg('"'), "https://gitlab.example.com/my-group/infra-automation/-/jobs/91020/artifacts/download?file_type=dotenv")
end

T["the filter shows matches with their ancestors and restores the folds"] = function()
  local v = open()
  ready(v)
  goto_node(v, "a:91022:archive")
  keys("<CR>")
  H.wait_for(function()
    return v.listing[91022] and v.listing[91022].status == "listed"
  end)
  local before = lines(v)
  v.shell.prompt:set_text("coverage")
  H.wait_for(function()
    return v.query == "coverage"
  end)
  local s = text(v)
  eq(s:find("    ╰── ▾ reports/", 1, true) ~= nil, true)
  eq(s:find("coverage.xml", 1, true) ~= nil, true)
  eq(s:find("#4819", 1, true), nil)
  v.shell.prompt:set_text("")
  H.wait_for(function()
    return v.query == ""
  end)
  eq(lines(v), before)
  v.shell.prompt:set_text("job:nothing-like-this")
  H.wait_for(function()
    return v.query ~= ""
  end)
  eq(text(v):find("No artifacts match", 1, true) ~= nil, true)
end

T["P shows more pipelines when there are more"] = function()
  local saved_n = view.PIPELINES
  view.PIPELINES = 2
  local ok, err = pcall(function()
    local v = open()
    ready(v)
    eq(#v.tree.roots, 2)
    local title = vim.api.nvim_win_get_config(v.shell.table_float.win).title
    eq(title[1][1]:find("[P] more", 1, true) ~= nil, true)
    keys("P")
    eq(#v.tree.roots, 4)
  end)
  view.PIPELINES = saved_n
  if not ok then
    error(err)
  end
end

return T
