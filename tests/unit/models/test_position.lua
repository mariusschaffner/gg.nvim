local position = require("gg.models.position")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["sha1: known vectors"] = function()
  eq(position.sha1(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
  eq(position.sha1("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
  eq(position.sha1("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"), "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
  eq(position.sha1("The quick brown fox jumps over the lazy dog"), "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
end

T["line_code: sha1 of the path, old and new line"] = function()
  eq(position.line_code("abc", { new_line = 7 }), "a9993e364706816aba3e25717850c26c9cd0d89d_0_7")
  eq(position.line_code("abc", { old_line = 3, new_line = 4 }), "a9993e364706816aba3e25717850c26c9cd0d89d_3_4")
end

T["line: added, removed and unchanged lines"] = function()
  eq(position.line({ new_path = "a.lua" }, { new_line = 5 }), { new_path = "a.lua", old_path = "a.lua", position_type = "text", new_line = 5 })
  eq(position.line({ new_path = "b.lua", old_path = "a.lua" }, { old_line = 2 }), { new_path = "b.lua", old_path = "a.lua", position_type = "text", old_line = 2 })
  eq(position.line({ new_path = "a.lua" }, { old_line = 2, new_line = 3 }).old_line, 2)
end

T["range: anchored on the last line, with line codes"] = function()
  local p = position.range({ new_path = "abc" }, { old_line = 3 }, { old_line = 5, new_line = 4 })
  eq({ p.old_line, p.new_line }, { 5, 4 })
  eq(p.line_range.start, { line_code = "a9993e364706816aba3e25717850c26c9cd0d89d_3_0", type = "old", old_line = 3 })
  eq(p.line_range["end"], { line_code = "a9993e364706816aba3e25717850c26c9cd0d89d_5_4", old_line = 5, new_line = 4 })
  eq(position.range({ new_path = "abc" }, { new_line = 1 }, { new_line = 2 }).line_range.start.type, "new")
end

T["file: a whole-file position"] = function()
  eq(position.file({ new_path = "a.lua" }), { new_path = "a.lua", old_path = "a.lua", position_type = "file" })
end

T["check"] = function()
  eq({ position.check({ new_path = "a" }) }, {})
  eq({ position.check("x") }, { "position", "must be a table" })
  eq(position.check({ new_line = 1 }), "position.new_path")
  eq(position.check({ new_path = "a", bogus = 1 }), "position.bogus")
  eq(position.check({ new_path = "a", new_line = "1" }), "position.new_line")
end

return T
