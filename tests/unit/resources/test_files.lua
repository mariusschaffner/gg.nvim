-- Pagination: not applicable (one file per call).
local H = require("tests.helpers")
local files = require("gg.resources.files")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, MP = H.TEST_HOST, "my-group/my-project"
local SHA = "33e2ee8579fda5bc36accc9c6fbd0b4fefda9e30"
local BODY = "class Key\n  def name\n  end\nend\n"

T["raw: streamed to a file; the path is one encoded segment"] = function()
  local fake = H.fake({ "rest/files/raw.json" })
  local out = vim.fn.tempname()
  local d = H.await(files.raw({ host = HOST, project = MP, path = "app/models/key.rb", ref = SHA, output = out }))
  eq(d, { path = out, bytes = #BODY })
  eq(H.read(out), BODY)
  eq(fake:last().path, "/api/v4/projects/my-group%2Fmy-project/repository/files/app%2Fmodels%2Fkey.rb/raw")
  eq(fake:last().query, { ref = SHA })
  os.remove(out)
end

T["raw: to a callback"] = function()
  H.fake({ "rest/files/raw.json" })
  local chunks = {}
  local d = H.await(files.raw({ host = HOST, project = MP, path = "app/models/key.rb", ref = SHA, on_chunk = function(c)
    table.insert(chunks, c)
  end }))
  eq(table.concat(chunks), BODY)
  eq(d.bytes, #BODY)
end

T["raw: errors and validation"] = function()
  H.fake({ "rest/files/raw.json" })
  local out = vim.fn.tempname()
  local _, err = H.await(files.raw({ host = HOST, project = MP, path = "missing.rb", ref = "main", output = out }))
  eq(err.kind, "not_found")
  eq(vim.uv.fs_stat(out), nil)
  eq(select(2, H.await(files.raw({ host = HOST, project = MP, path = "a", ref = "main" }))).details.key, "output")
  eq(select(2, H.await(files.raw({ host = HOST, project = MP, path = "a", output = out }))).details.key, "ref")
  eq(select(2, H.await(files.raw({ host = HOST, project = MP, ref = "main", output = out }))).details.key, "path")
end

return T
