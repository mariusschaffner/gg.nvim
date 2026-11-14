local diff = require("gg.models.diff")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["count_lines skips file headers and context"] = function()
  eq({ diff.count_lines("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n+c\n ctx\n") }, { 2, 1 })
  eq({ diff.count_lines("") }, { 0, 0 })
end

T["parse: hunks with old and new line numbers"] = function()
  local hunks = diff.parse("--- a/x\n+++ b/x\n@@ -3,4 +3,5 @@ function f()\n a\n-b\n+B\n+C\n d\n@@ -20 +21,0 @@\n-z\n\\ No newline at end of file\n")
  eq(#hunks, 2)
  local h = hunks[1]
  eq({ h.old_start, h.old_count, h.new_start, h.new_count, h.section }, { 3, 4, 3, 5, "function f()" })
  eq(h.lines[1], { kind = "context", old_line = 3, new_line = 3, text = "a" })
  eq(h.lines[2], { kind = "delete", old_line = 4, text = "b" })
  eq(h.lines[3], { kind = "add", new_line = 4, text = "B" })
  eq(h.lines[4], { kind = "add", new_line = 5, text = "C" })
  eq(h.lines[5], { kind = "context", old_line = 5, new_line = 6, text = "d" })
  eq({ hunks[2].old_count, hunks[2].new_count, hunks[2].section }, { 1, 0, "" })
  eq(hunks[2].lines, { { kind = "delete", old_line = 20, text = "z", no_newline = true } })
end

T["parse: empty and CRLF"] = function()
  eq(diff.parse(""), {})
  eq(diff.parse(nil), {})
  eq(diff.parse("@@ -1 +1 @@\r\n-a\r\n+b\r\n")[1].lines[2], { kind = "add", new_line = 1, text = "b" })
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

T["summary_from_graphql and file_stat_from_graphql"] = function()
  eq(diff.summary_from_graphql({ additions = 3, deletions = 2, fileCount = 1 }), { additions = 3, deletions = 2, changes = 5, file_count = 1 })
  eq(diff.summary_from_graphql(vim.NIL), nil)
  eq(diff.file_stat_from_graphql({ path = "a.lua", additions = 1, deletions = vim.NIL }), { path = "a.lua", additions = 1, deletions = 0 })
  eq(diff.file_stat_from_graphql({ additions = 1 }), nil)
end

return T
