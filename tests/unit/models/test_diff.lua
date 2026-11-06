local diff = require("gg.models.diff")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["count_lines skips file headers and context"] = function()
  eq({ diff.count_lines("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n+c\n ctx\n") }, { 2, 1 })
  eq({ diff.count_lines("") }, { 0, 0 })
end

T["stat: collapsed diffs have nil counts"] = function()
  local f = diff.file_from_rest({ old_path = "a", new_path = "a", diff = "", collapsed = true })
  eq(diff.stat(f), { path = "a", status = "modified" })
end

T["version_from_rest exposes diff refs"] = function()
  local v = diff.version_from_rest({ id = "7", head_commit_sha = "h", base_commit_sha = "b", start_commit_sha = "s" })
  eq(v.id, 7)
  eq(v.diff_refs, { base_sha = "b", head_sha = "h", start_sha = "s" })
  eq(diff.version_from_rest(vim.NIL), nil)
end

T["commit_from_graphql"] = function()
  local c = diff.commit_from_graphql({ sha = "abc", shortId = "ab", title = "t", author = vim.NIL })
  eq({ c.sha, c.short_sha, c.title, c.author }, { "abc", "ab", "t", nil })
end

return T
