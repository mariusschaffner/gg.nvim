-- Pagination: not applicable (artifacts has no list call; a job's artifact
-- list is part of gg.Job).
local H = require("tests.helpers")
local artifacts = require("gg.resources.artifacts")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, MP = H.TEST_HOST, "my-group/my-project"
local ZIP = vim.base64.decode("UEsDBBQAAAAAAGZha2V6aXBjb250ZW50LWZvci10ZXN0cwABAgM=")

local function tmp()
  return vim.fn.tempname() .. ".zip"
end

T["download: archive streamed to a file"] = function()
  local fake = H.fake({ "rest/artifacts/downloads.json" })
  local out = tmp()
  local d = H.await(artifacts.download({ host = HOST, project = MP, job_id = 42, output = out }))
  eq(d, { path = out, bytes = #ZIP })
  eq(H.read(out), ZIP)
  eq(fake:last().headers.Accept, "*/*")
  os.remove(out)
end

T["download: a redirect to object storage drops the token"] = function()
  local fake = H.fake({ "rest/artifacts/downloads.json" })
  local out = tmp()
  local d = H.await(artifacts.download({ host = HOST, project = MP, job_id = 43, output = out }))
  eq(d.bytes, #ZIP)
  local reqs = fake:requests()
  eq(#reqs, 2)
  eq(reqs[1].headers["PRIVATE-TOKEN"], H.TEST_TOKEN)
  eq(reqs[2].url, "https://storage.example.net/artifacts/43/archive.zip?X-Signature=abc")
  eq(reqs[2].headers["PRIVATE-TOKEN"], nil)
  os.remove(out)
end

T["download_file: segments encoded, slashes kept; to a callback"] = function()
  local fake = H.fake({ "rest/artifacts/downloads.json" })
  local chunks = {}
  local d = H.await(artifacts.download_file({ host = HOST, project = MP, job_id = 42, artifact_path = "coverage/report final.txt", on_chunk = function(c)
    table.insert(chunks, c)
  end }))
  eq(table.concat(chunks), "coverage: 87.5%\n")
  eq(d, { bytes = 16 })
  eq(fake:last().path, "/api/v4/projects/my-group%2Fmy-project/jobs/42/artifacts/coverage/report%20final.txt")
end

T["download_ref and download_ref_file: ref is one encoded segment"] = function()
  local fake = H.fake({ "rest/artifacts/downloads.json" })
  local out = tmp()
  H.await(artifacts.download_ref({ host = HOST, project = MP, ref = "feature/login", job = "build", output = out }))
  eq(fake:last().path, "/api/v4/projects/my-group%2Fmy-project/jobs/artifacts/feature%2Flogin/download")
  eq(fake:last().query, { job = "build" })
  os.remove(out)
  local out2 = vim.fn.tempname()
  local d = H.await(artifacts.download_ref_file({ host = HOST, project = MP, ref = "main", job = "build", artifact_path = "dist/app.js", output = out2 }))
  eq(H.read(out2), "console.log(1)\n")
  eq(d.bytes, 15)
  os.remove(out2)
end

T["404 is not_found and leaves no file"] = function()
  H.fake({ "rest/artifacts/downloads.json" })
  local out = tmp()
  local _, err = H.await(artifacts.download({ host = HOST, project = MP, job_id = 44, output = out }))
  eq(err.kind, "not_found")
  eq(vim.uv.fs_stat(out), nil)
end

T["validation: a sink is required, paths stay inside the artifacts"] = function()
  H.fake()
  local cases = {
    { artifacts.download, { host = HOST, project = MP, job_id = 1 } },
    { artifacts.download_file, { host = HOST, project = MP, job_id = 1, artifact_path = "a.txt" } },
    { artifacts.download_file, { host = HOST, project = MP, job_id = 1, artifact_path = "a.txt", output = "/tmp/a", on_chunk = function() end } },
    { artifacts.download_file, { host = HOST, project = MP, job_id = 1, artifact_path = "../../etc/passwd", output = "/tmp/a" } },
    { artifacts.download_ref, { host = HOST, project = MP, ref = "main", output = "/tmp/a" } },
    { artifacts.download_ref_file, { host = HOST, project = MP, ref = "main", job = "b", artifact_path = "x/..", output = "/tmp/a" } },
  }
  for i, c in ipairs(cases) do
    local _, err = H.await(c[1](c[2]))
    if not err or err.kind ~= "validation" then
      error(("case %d: expected validation, got %s"):format(i, vim.inspect(err)))
    end
  end
end

return T
