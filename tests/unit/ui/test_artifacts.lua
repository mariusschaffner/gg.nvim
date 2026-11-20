-- The pure parts of the artifacts view: sizes, expiry, the zip reader, the
-- tree model, the filter, the columns and the renderer.
local D = require("tests.support.artifact_data")
local columns = require("gg.ui.artifacts.columns")
local expires = require("gg.ui.artifacts.expires")
local filter = require("gg.ui.artifacts.filter")
local model = require("gg.ui.artifacts.model")
local paths = require("gg.ui.artifacts.paths")
local render = require("gg.ui.artifacts.render")
local size = require("gg.ui.lib.size")
local zip = require("gg.ui.artifacts.zip")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function tree(opts)
  opts = opts or {}
  return model.build(D.jobs(), {
    now = D.NOW,
    show_expired = opts.show_expired,
    entries = opts.entries or { [91022] = D.entries() },
    listing = opts.listing or { [91022] = { status = "listed" } },
  })
end

-- the mockup's open state
local function mockup_open()
  return {
    ["p:4819"] = true,
    ["p:4812"] = true,
    ["a:91022:archive"] = true,
    ["d:91022:dist/"] = true,
    ["d:91022:reports/"] = true,
  }
end

local function ids(rows)
  return vim.tbl_map(function(r)
    return r.kind == "status" and ("status:" .. r.status) or r.node.id
  end, rows)
end

-- the Name column text of the body lines (after the head)
local function names(r)
  local out = {}
  for lnum, info in pairs(r.rows) do
    if info.node then
      local l = r.lines[lnum]
      local name = vim.trim(l:sub(info.mark_col + 3)):gsub("%s%s+[%d%.]+ [KMG]?B.*$", "")
      table.insert(out, { lnum, name })
    end
  end
  table.sort(out, function(a, b)
    return a[1] < b[1]
  end)
  return vim.tbl_map(function(x)
    return x[2]
  end, out)
end

-- sizes ---------------------------------------------------------------------

T["size: base 1024, KB whole, one decimal from MB"] = function()
  eq(size.human(6), "6 B")
  eq(size.human(512), "512 B")
  eq(size.human(1023), "1023 B")
  eq(size.human(1024), "1 KB")
  eq(size.human(12288), "12 KB")
  eq(size.human(1024 * 1024 - 1), "1.0 MB")
  eq(size.human(1887436), "1.8 MB")
  eq(size.human(13002342), "12.4 MB")
  eq(size.human(12.4 * 1024 ^ 3), "12.4 GB")
  eq(size.human(nil), "")
end

-- expiry --------------------------------------------------------------------

T["expires: kept, today, soon, later, expired"] = function()
  local now = D.NOW
  eq({ expires.cell({ expire_at = nil }, now) }, { "kept", "GitlabArtifactKept" })
  eq({ expires.cell({ expire_at = D.iso(3600) }, now) }, { "today", "GitlabArtifactExpiring" })
  eq({ expires.cell({ expire_at = D.iso(86400 + 60) }, now) }, { "in 1d", "GitlabArtifactExpiring" })
  eq({ expires.cell({ expire_at = D.iso(2 * 86400 + 60) }, now) }, { "in 2d", "GitlabArtifactExpiring" })
  eq({ expires.cell({ expire_at = D.iso(6 * 86400 + 60) }, now) }, { "in 6d", "Comment" })
  eq({ expires.cell({ expire_at = D.iso(-60) }, now) }, { "expired", "GitlabArtifactExpired" })
  eq({ expires.cell({ expire_at = nil, expired = true }, now) }, { "expired", "GitlabArtifactExpired" })
  eq(expires.kept({ expire_at = nil }), true)
  eq(expires.expiring({ expire_at = D.iso(86400) }, now), true)
  eq(expires.expiring({ expire_at = nil }, now), false)
end

-- zip -----------------------------------------------------------------------

T["zip: central directory of a plain archive, directories skipped"] = function()
  local bytes, cd_offset = D.zip({ { path = "dist/", size = 0 }, { path = "dist/a.tar.gz", size = 900 }, { path = "VERSION", size = 6 } })
  local dir = zip.eocd(bytes, 0)
  eq(dir.cd_offset, cd_offset)
  eq(dir.count, 3)
  local entries = zip.entries(bytes:sub(dir.cd_offset + 1, dir.cd_offset + dir.cd_size))
  eq(entries, { { path = "dist/a.tar.gz", size = 900 }, { path = "VERSION", size = 6 } })
end

T["zip: a comment, and only the tail of the file"] = function()
  local bytes = D.zip({ { path = "a.txt", size = 1 } }, { comment = "PK\5\6 a comment that looks like a record", prefix = string.rep("x", 1000) })
  local tail_offset = #bytes - 200
  local dir = zip.eocd(bytes:sub(tail_offset + 1), tail_offset)
  eq(dir.count, 1)
  eq(zip.entries(bytes:sub(dir.cd_offset + 1, dir.cd_offset + dir.cd_size)), { { path = "a.txt", size = 1 } })
end

T["zip: Zip64 record and sizes over 4 GiB"] = function()
  local bytes = D.zip({ { path = "huge.bin", size = 5 * 1024 ^ 3 }, { path = "small", size = 3 } }, { zip64 = true })
  local dir = zip.eocd(bytes, 0)
  eq(dir.count, 2)
  local entries = zip.entries(bytes:sub(dir.cd_offset + 1, dir.cd_offset + dir.cd_size))
  eq(entries, { { path = "huge.bin", size = 5 * 1024 ^ 3 }, { path = "small", size = 3 } })
  -- the Zip64 record outside the tail is asked for, then parsed apart
  local tail_offset = #bytes - 22 - 20
  local need = zip.eocd(bytes:sub(tail_offset + 1), tail_offset)
  eq(need.need.length, 56)
  local rec = bytes:sub(need.need.offset + 1, need.need.offset + 56)
  eq(zip.eocd64(rec), dir)
end

T["zip: not a zip, corrupt or truncated directory"] = function()
  local _, err = zip.eocd("hello world, this is not a zip archive at all", 0)
  eq(err:find("not a zip", 1, true) ~= nil, true)
  eq(select(2, zip.entries("garbage")), "corrupt central directory")
  local bytes = D.zip({ { path = "a.txt", size = 1 } })
  local dir = zip.eocd(bytes, 0)
  local cd = bytes:sub(dir.cd_offset + 1, dir.cd_offset + dir.cd_size)
  eq(select(2, zip.entries(cd:sub(1, 30))), "truncated central directory")
  eq(select(2, zip.eocd64("nope")), "bad Zip64 end record")
end

-- model ---------------------------------------------------------------------

T["model: pipelines newest first; logs, metadata and expired left out"] = function()
  local t = tree()
  eq(vim.tbl_map(function(r)
    return r.id
  end, t.roots), { "p:4819", "p:4817", "p:4815", "p:4812", "p:4808" })
  local p12 = t.by_id["p:4812"]
  eq({ p12.count, p12.size }, { 2, 13002342 + 512 })
  eq(vim.tbl_map(function(c)
    return c.id
  end, p12.children), { "a:91022:archive", "a:91020:dotenv" })
  eq(t.by_id["a:91060:metadata"], nil)
  eq(t.by_id["p:4806"], nil)
  local shown = tree({ show_expired = true })
  eq(shown.by_id["a:90988:archive"].expired, true)
  eq(model.expandable(shown.by_id["a:90988:archive"]), false)
end

T["model: archive entries become folders with sums and file counts"] = function()
  local t = tree()
  local art = t.by_id["a:91022:archive"]
  eq(vim.tbl_map(function(c)
    return c.name
  end, art.children), { "dist", "modules", "reports", "build.log", "VERSION" })
  local modules = t.by_id["d:91022:modules/"]
  eq({ modules.size, modules.files }, { 10240, 4 })
  eq(t.by_id["d:91022:reports/"].size, 202752)
  eq(t.by_id["d:91022:modules/edge-lb/"].parent, "d:91022:modules/")
  eq(t.by_id["f:91022:reports/coverage.xml"].parent, "d:91022:reports/")
  eq(model.parent(t, "f:91022:VERSION").id, "a:91022:archive")
  eq(model.parent(t, "p:4812"), nil)
  -- tree API entries carry directories too (an empty one stays)
  local t2 = model.build(D.jobs(), { now = D.NOW, entries = { [91022] = { { path = "empty/", type = "directory" }, { path = "a", size = 1, type = "file" } } } })
  eq(t2.by_id["d:91022:empty/"].files, 0)
end

T["model: default open, listing state, open_all skips unlisted archives"] = function()
  local t = tree()
  eq(model.default_open(t, "main"), { ["p:4819"] = true, ["p:4812"] = true })
  eq(model.listing(t, t.by_id["a:91022:archive"]), "listed")
  eq(model.listing(t, t.by_id["a:91024:archive"]), "unlisted")
  local open = {}
  model.open_all(t, open)
  eq(open["a:91022:archive"], true)
  eq(open["d:91022:modules/edge-lb/"], true)
  eq(open["a:91024:archive"], nil)
  eq(open["p:4815"], true)
  eq(#model.files_below(t.by_id["d:91022:modules/"]), 4)
  eq(#model.files_below(t.by_id["p:4812"]), 11)
end

T["model: flatten walks open nodes; loading and error rows"] = function()
  local t = tree()
  local rows = model.flatten(t, { ["p:4812"] = true })
  eq(ids(rows), { "p:4819", "p:4817", "p:4815", "p:4812", "a:91022:archive", "a:91020:dotenv", "p:4808" })
  eq(rows[5].lasts, { false })
  eq(rows[6].lasts, { true })
  local loading = model.build(D.jobs(), { now = D.NOW, listing = { [91024] = { status = "loading" } } })
  local r2 = model.flatten(loading, { ["p:4815"] = true, ["a:91024:archive"] = true })
  eq(ids(r2), { "p:4819", "p:4817", "p:4815", "a:91024:archive", "status:loading", "a:91031:junit", "p:4812", "p:4808" })
  eq(r2[5].lasts, { false, true })
end

-- filter --------------------------------------------------------------------

local function visible_ids(t, query, open)
  local res = filter.apply(t, filter.parse(query), D.NOW)
  local o = vim.tbl_extend("force", open or {}, res and res.auto_open or {})
  return ids(model.flatten(t, o, res and res.visible)), res
end

T["filter: a name deep in an archive opens its ancestors"] = function()
  local t = tree()
  local got, res = visible_ids(t, "coverage")
  eq(got, { "p:4812", "a:91022:archive", "d:91022:reports/", "f:91022:reports/coverage.xml" })
  eq(res.hits, 1)
end

T["filter: tokens combine along the path; #id, ref:, job:, type:"] = function()
  local t = tree()
  eq((visible_ids(t, "#481")), { "p:4819", "p:4817", "p:4815", "p:4812" })
  eq((visible_ids(t, "#4812")), { "p:4812" })
  eq((visible_ids(t, "ref:main type:report", {})), { "p:4812", "a:91020:dotenv" })
  eq((visible_ids(t, "job:checkov")), { "p:4819", "a:91041:sarif" })
  -- a pipeline that matches keeps its subtree, folded as before
  eq((visible_ids(t, "ref:rotate", { ["p:4817"] = true })), { "p:4817", "a:91052:terraform" })
  eq((visible_ids(t, "ref:main build.log")), { "p:4812", "a:91022:archive", "f:91022:build.log" })
end

T["filter: kept and expiring"] = function()
  local t = tree()
  eq((visible_ids(t, "kept")), { "p:4812", "a:91022:archive" })
  eq((visible_ids(t, "expiring")), { "p:4808", "a:91060:archive" })
end

T["filter: never opens an archive that is not listed; empty query is nil"] = function()
  local t = tree()
  local got = visible_ids(t, "dns01")
  eq(got, { "p:4815" })
  local _, res = visible_ids(t, "artifacts.zip")
  eq(res.auto_open["a:91024:archive"], nil)
  eq(filter.apply(t, filter.parse("  "), D.NOW), nil)
end

-- columns and render ----------------------------------------------------------

T["columns: Expires hides first, then Size"] = function()
  local wide = columns.layout(100)
  eq({ wide.size ~= nil, wide.expires ~= nil, wide.name.width }, { true, true, 100 - 2 - 12 - 12 })
  local mid = columns.layout(2 + 30 + 12 + 5)
  eq({ mid.size ~= nil, mid.expires }, { true, nil })
  local narrow = columns.layout(34)
  eq({ narrow.size, narrow.expires }, { nil, nil })
end

local function rendered(open, width)
  local t = tree()
  return render.render({
    width = width or 100,
    status = "ready",
    tree = t,
    open = open or mockup_open(),
    default_branch = "main",
    now = D.NOW,
    retry_key = "R",
  })
end

T["render: the mockup tree, guides and chevrons"] = function()
  local r = rendered()
  eq(names(r), {
    "▾ ✗ #4819  feat/oci-edge-lb  · 1h ago  · 2 artifacts",
    "├── test:checkov  › results.sarif",
    "╰── test:tflint  › tflint.json",
    "▸ ▸ #4817  feat/rotate-tf-creds  · 2h ago  · 1 artifact",
    "▸ ✓ #4815  feat/dns01-wildcard  · 3h ago  · 2 artifacts",
    "▾ ✓ #4812  main  · 8h ago  · 2 artifacts",
    "├── ▾ build:package  › artifacts.zip",
    "│   ├── ▾ dist/",
    "│   │   ├── checksums.sha256",
    "│   │   ╰── infra-automation-1.4.2.tar.gz",
    "│   ├── ▸ modules/  4 files",
    "│   ├── ▾ reports/",
    "│   │   ├── coverage.xml",
    "│   │   ╰── terraform-docs.md",
    "│   ├── build.log",
    "│   ╰── VERSION",
    "╰── build:vars  › build.env",
    "▸ ✓ #4808  main  · 1d ago  · 1 artifact",
  })
end

T["render: header, sizes right-aligned, expires, separators"] = function()
  local r = rendered()
  eq(r.lines[1], "")
  eq(r.lines[2]:match("^%s*(Name)"), "Name")
  eq(r.lines[2]:match("Size%s+Expires$") ~= nil, true)
  local by_id = {}
  for lnum, info in pairs(r.rows) do
    if info.node then
      by_id[info.node.id] = r.lines[lnum]
    end
  end
  eq(by_id["p:4812"]:match("12%.4 MB$") ~= nil, true)
  eq(by_id["a:91022:archive"]:match("12%.4 MB  kept$") ~= nil, true)
  eq(by_id["a:91020:dotenv"]:match("512 B  in 29d$") ~= nil, true)
  eq(by_id["f:91022:VERSION"]:match("6 B$") ~= nil, true)
  -- the size column ends 12 cells before the end (gap + expires)
  local size_end = vim.fn.strdisplaywidth(by_id["f:91022:VERSION"])
  eq(size_end, 100 - 12)
  -- separators below the last row of each pipeline but the last
  eq(#r.virt_lines, 4)
  eq(r.virt_lines[1].chunks[1][2], "GitlabSeparator")
  -- only node rows are selectable
  eq(#r.selectable, 18)
end

T["render: highlights by kind and extension"] = function()
  local r = rendered()
  local hls = {}
  for _, m in ipairs(r.marks) do
    hls[m.hl] = true
  end
  for _, hl in ipairs({
    "GitlabTreeGuide",
    "GitlabTreeChevron",
    "GitlabTreeDir",
    "GitlabTreeRoot",
    "GitlabArtifactJob",
    "GitlabArtifactKept",
    "GitlabFileMarkdown",
    "GitlabFileData",
    "GitlabFileSecurity",
    "GitlabFileArchive",
    "GitlabFileEnv",
    "GitlabRefDefault",
    "GitlabBranchSource",
    "GitlabPipelineFailed",
    "GitlabColumnHeader",
  }) do
    eq({ hl, hls[hl] }, { hl, true })
  end
  eq(render.ext_hl("main.TF"), "GitlabFileCode")
  eq(render.ext_hl("VERSION"), nil)
  eq(render.ref_hl({ ref = "v1", tag = true }, "main"), "GitlabRefTag")
end

T["render: loading and error rows under an archive; states; narrow"] = function()
  local t = model.build(D.jobs(), { now = D.NOW, listing = { [91024] = { status = "error", error = "404 Not Found" }, [91060] = { status = "loading" } } })
  local r = render.render({
    width = 100,
    status = "ready",
    tree = t,
    open = { ["p:4815"] = true, ["a:91024:archive"] = true, ["p:4808"] = true, ["a:91060:archive"] = true },
    now = D.NOW,
    retry_key = "R",
  })
  local text_of = table.concat(r.lines, "\n")
  eq(text_of:find("│   ╰── ✗ 404 Not Found · [R] retry", 1, true) ~= nil, true)
  eq(text_of:find("    ╰── ◐ loading…", 1, true) ~= nil, true)
  local loading = render.render({ width = 80, status = "loading", open = {}, now = D.NOW })
  eq(vim.trim(loading.lines[#loading.lines]), "Loading artifacts…")
  local empty = render.render({ width = 80, status = "ready", tree = t, open = {}, visible = {}, now = D.NOW })
  eq(vim.trim(empty.lines[#empty.lines]), "No artifacts match")
  local failed = render.render({ width = 80, status = "error", error = "boom", retry_key = "R", open = {}, now = D.NOW })
  eq(vim.trim(failed.lines[#failed.lines - 1]), "Failed to load artifacts: boom")
  local narrow = render.render({ width = 40, status = "ready", tree = t, open = {}, now = D.NOW })
  eq(narrow.columns.size, nil)
  for _, l in ipairs(narrow.lines) do
    eq(vim.fn.strdisplaywidth(l) <= 40, true)
  end
end

T["render: optional icons before file names"] = function()
  local t = tree()
  local r = render.render({
    width = 100,
    status = "ready",
    tree = t,
    open = mockup_open(),
    now = D.NOW,
    icon_of = function(name)
      return name:match("%.md$") and "M" or nil, "Special"
    end,
  })
  eq(table.concat(r.lines, "\n"):find("╰── M terraform-docs.md", 1, true) ~= nil, true)
end

-- paths -----------------------------------------------------------------------

T["paths: download targets, buffer names, copied paths and URLs"] = function()
  local t = tree()
  local base = paths.base("/home/u/Downloads/", "my-group/infra-automation", 4812)
  eq(base, "/home/u/Downloads/gitlab/infra-automation/4812")
  eq(paths.target(base, t.by_id["f:91022:reports/terraform-docs.md"]), base .. "/reports/terraform-docs.md")
  eq(paths.target(base, t.by_id["a:91022:archive"]), base .. "/build_package/artifacts.zip")
  eq(paths.target(base, t.by_id["a:91020:dotenv"]), base .. "/build_vars/build.env")
  eq(paths.target(base, t.by_id["d:91022:reports/"]), nil)
  eq(paths.segment(".."), "_")
  eq(paths.buffer_name(t.by_id["f:91022:reports/terraform-docs.md"]), "gitlab://artifacts/91022/reports/terraform-docs.md")
  eq(paths.buffer_name(t.by_id["a:91020:dotenv"]), "gitlab://artifacts/91020/build.env")
  eq(paths.inner_path(t.by_id["f:91022:reports/coverage.xml"]), "reports/coverage.xml")
  eq(paths.inner_path(t.by_id["a:91022:archive"]), "artifacts.zip")
  eq(paths.inner_path(t.by_id["p:4812"]), nil)
  local job = "https://gitlab.example.com/my-group/infra-automation/-/jobs/"
  eq(paths.web_url(t.by_id["f:91022:reports/coverage.xml"]), job .. "91022/artifacts/file/reports/coverage.xml")
  eq(paths.web_url(t.by_id["d:91022:reports/"]), job .. "91022/artifacts/browse/reports")
  eq(paths.web_url(t.by_id["a:91022:archive"]), job .. "91022/artifacts/browse")
  eq(paths.web_url(t.by_id["a:91020:dotenv"]), job .. "91020/artifacts/download?file_type=dotenv")
  eq(paths.web_url(t.by_id["p:4812"]), "https://gitlab.example.com/my-group/infra-automation/-/pipelines/4812")
  eq({ paths.sniff("plain text" .. string.char(10)) }, { false, false })
  eq({ paths.sniff("a" .. string.char(0) .. "b") }, { true, false })
  eq({ paths.sniff(string.char(0x1f, 0x8b, 8)) }, { true, true })
end

T["model: max_roots keeps the newest pipelines and counts them all"] = function()
  local t = model.build(D.jobs(), { now = D.NOW, max_roots = 2 })
  eq(#t.roots, 2)
  eq(t.total, 5)
  eq(t.by_id["p:4815"], nil)
  eq(t.by_id["a:91060:archive"], nil)
end

return T
