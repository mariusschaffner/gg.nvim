-- gg.ui.create: the pure parts (layout, model, placeholders, variables, mr).
local layout = require("gg.ui.create.layout")
local model = require("gg.ui.create.model")
local mr = require("gg.ui.create.mr")
local placeholders = require("gg.ui.create.placeholders")
local variables = require("gg.ui.create.variables")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["layout.box: 70 % of the editor, centred"] = function()
  eq(layout.box({ columns = 200, lines = 50 }), { row = 7, col = 30, width = 140, height = 35 })
end

T["layout.box: minimum size, or the whole editor when it is smaller"] = function()
  eq(layout.box({ columns = 80, lines = 18 }), { row = 2, col = 10, width = 60, height = 14 })
  eq(layout.box({ columns = 50, lines = 10 }), { row = 0, col = 0, width = 50, height = 10 })
end

T["layout.rects: title, body, one empty row apart"] = function()
  local r = layout.rects(0, { columns = 200, lines = 50 })
  eq(r.title, { row = 7, col = 30, width = 138, height = 1 })
  eq(r.fields, {})
  -- title takes rows 7..9, row 10 is empty, the body ends with the box (row 41)
  eq(r.body, { row = 11, col = 30, width = 138, height = 29 })
  eq(r.body.row + r.body.height + 2, 7 + 35)
end

T["layout.rects: two fields side by side, two cells apart, equal width"] = function()
  local r = layout.rects(2, { columns = 200, lines = 50 })
  eq(r.fields, {
    { row = 11, col = 30, width = 67, height = 1 },
    { row = 11, col = 101, width = 67, height = 1 },
  })
  -- left edge + outer width + gap = the second one's left edge; both end with the box
  eq(30 + 69 + 2, 101)
  eq(101 + 69, 30 + 140)
  eq(r.body, { row = 15, col = 30, width = 138, height = 25 })
  -- an odd width: the last field takes the extra cell
  local odd = layout.rects(2, { columns = 201, lines = 50 })
  eq(odd.fields[1].col + odd.fields[1].width + 2 + 2, odd.fields[2].col)
  eq(odd.fields[2].col + odd.fields[2].width + 2, odd.title.col + odd.title.width + 2)
end

T["layout.rects: one field spans the box; the body never vanishes"] = function()
  local r = layout.rects(1, { columns = 200, lines = 50 })
  eq(r.fields, { { row = 11, col = 30, width = 138, height = 1 } })
  eq(layout.rects(2, { columns = 40, lines = 8 }).body.height, 1)
end

T["placeholders: find, wrap, is"] = function()
  local lines = { "I want to ‹what›", "", "- [ ] ‹criterion› and ‹more›", "broken ‹open" }
  local spans = placeholders.find(lines)
  eq(vim.tbl_map(function(p)
    return { p.row, p.text }
  end, spans), { { 1, "what" }, { 3, "criterion" }, { 3, "more" } })
  -- byte columns: the span covers both marks
  eq(lines[1]:sub(spans[1].col + 1, spans[1].end_col), "‹what›")
  eq(placeholders.wrap("KEY"), "‹KEY›")
  eq({ placeholders.is("‹value›"), placeholders.is("x ‹value›"), placeholders.is("‹a› = ‹b›"), placeholders.is("") }, { true, false, false, false })
end

T["placeholders.step: next and previous wrap around"] = function()
  local spans = placeholders.find({ "‹a› x ‹b›", "‹c›" })
  local function at(row, col, dir)
    return placeholders.step(spans, row, col, dir).text
  end
  eq(at(1, 0, 1), "b") -- the cursor is on ‹a›: the next one
  eq(at(1, 20, 1), "c")
  eq(at(2, 0, 1), "a") -- wraps
  eq(at(2, 0, -1), "b")
  eq(at(1, 0, -1), "c") -- wraps
  eq(placeholders.step({}, 1, 0, 1), nil)
end

T["variables.parse: key before the first =, trimmed; blank lines ignored"] = function()
  local entries, problems = variables.parse({ "DEPLOY_ENV = staging", "", "  URL=https://x.example.com/?a=b ", "EMPTY =" })
  eq(entries, {
    { lnum = 1, key = "DEPLOY_ENV", value = "staging" },
    { lnum = 3, key = "URL", value = "https://x.example.com/?a=b" },
    { lnum = 4, key = "EMPTY", value = "" },
  })
  eq(problems, {})
  eq(variables.count({ "A = 1", "", "  ", "B = 2" }), 2)
end

T["variables.parse: bad keys, duplicates and lines without = are problems"] = function()
  local entries, problems = variables.parse({ "A = 1", "1BAD = x", "A = 2", "no equals", " = v", variables.NEW_LINE, "OK = ‹value›" })
  eq(vim.tbl_map(function(e)
    return e.key .. "=" .. e.value
  end, entries), { "A=1", "OK=" })
  eq(vim.tbl_map(function(p)
    return p.lnum
  end, problems), { 2, 3, 4, 5, 6 })
  eq(problems[2].message, "A is already set on line 1")
  eq(problems[3].message, "expected KEY = value")
  eq(problems[4].message, "the key is missing")
  eq({ problems[1].col, problems[1].end_col }, { 0, 4 })
end

T["variables: line and payload"] = function()
  eq(variables.line("A", "b"), "A = b")
  eq(variables.NEW_LINE, "‹KEY› = ‹value›")
  local entries = variables.parse({ "A = 1", "", "CERT = abc" })
  eq(variables.payload(entries, { [3] = "file" }), {
    { key = "A", value = "1", type = "env_var" },
    { key = "CERT", value = "abc", type = "file" },
  })
end

T["mr: issue number, title and Closes line"] = function()
  eq({ mr.issue_iid("22-some-feature"), mr.issue_iid("feature/22-x"), mr.issue_iid("2026"), mr.issue_iid(nil) }, { 22, nil, nil, nil })
  eq(mr.title("test", "master"), "Merge test into master")
  eq(mr.title("22-x", "master", "Add sprint planning"), "Add sprint planning")
  eq(mr.title(nil, "master"), "")
  eq(mr.closes(22), "Closes #22")
  eq({ mr.is_generated(""), mr.is_generated("Merge a into b"), mr.is_generated("Merge the thing into shape now"), mr.is_generated("feat: x") }, { true, true, false, false })
end

T["mr.validate"] = function()
  eq({ mr.validate({ title = "x", source = "a", target = "b" }) }, {})
  eq({ mr.validate({ title = "x", source = "a", target = "a" }) }, { "Source and target branch are the same", "target" })
  eq({ mr.validate({ title = "x", target = "a" }) }, { "Pick a source branch", "source" })
  eq({ mr.validate({ title = "x", source = "a", target = "" }) }, { "Pick a target branch", "target" })
  eq({ mr.validate({ title = "  ", source = "a", target = "b" }) }, { "Title cannot be empty", "title" })
end

T["model: border labels"] = function()
  eq(model.title_label({ icon = "＋", label = "New issue", accent = "GitlabCreateIssue" }), { { " ＋ New issue ", "GitlabCreateIssue" } })
  eq(model.key_label("gB", "Source"), {
    { " ", "GitlabCreateHint" },
    { "[gB]", "GitlabCreateKey" },
    { " Source", "GitlabCreateHint" },
    { " ", "GitlabCreateHint" },
  })
  eq(model.key_label(nil, "Source"), { { " Source ", "GitlabCreateHint" } })
  local chunks = model.hints({ { key = "<Tab>", desc = "Next" }, { key = nil, desc = "Gone" }, { key = "<Esc><Esc>", desc = "Cancel" } })
  eq(table.concat(vim.tbl_map(function(c)
    return c[1]
  end, chunks)), " [<Tab>] Next • [<Esc><Esc>] Cancel ")
  eq(model.hints({ { desc = "x" } }), "")
end

T["model.submit_label: idle, busy, error"] = function()
  local o = { key = "<C-s>", submit = "Create", busy = "creating…" }
  eq(model.submit_label("idle", o), { { " [<C-s>] Create ", "GitlabCreateSubmit" } })
  eq(model.submit_label("busy", o), { { " creating… ", "GitlabCreateSubmit" } })
  local err = model.submit_label("error", { submit = "Create", busy = "x", error = string.rep("e", 80) })
  eq(err[1][2], "GitlabCreateError")
  eq(vim.fn.strdisplaywidth(err[1][1]), model.ERROR_MAX + 2)
  eq(model.submit_label("idle", { submit = "Run", busy = "x" }), { { " Run ", "GitlabCreateSubmit" } })
end

T["model.dirty, cycle, body_text"] = function()
  local a = { title = "t", body = { "x", "" }, fields = { source = "a" } }
  eq(model.dirty(a, vim.deepcopy(a)), false)
  eq(model.dirty(a, { title = "t2", body = { "x", "" }, fields = { source = "a" } }), true)
  eq(model.dirty(a, { title = "t", body = { "x", "y" }, fields = { source = "a" } }), true)
  eq(model.dirty(a, { title = "t", body = { "x", "" }, fields = { source = "b" } }), true)
  local order = { "title", "source", "target", "body" }
  eq({ model.cycle(order, "title", 1), model.cycle(order, "body", 1), model.cycle(order, "title", -1), model.cycle(order, nil, 1), model.cycle({}, "x", 1) }, { "source", "title", "body", "title" })
  eq(model.body_text({ "a", "", "b", "", "  " }), "a\n\nb")
  eq(model.body_text({ "" }), "")
end

T["model.field_errors: API messages go to the float they name"] = function()
  local err = { kind = "validation", message = "400 Bad Request: description is too long (maximum is 1048576 characters); title is too long (maximum is 255 characters)" }
  local by, other = model.field_errors(err, { title = "title", description = "body" })
  eq(by, { title = "is too long (maximum is 255 characters)", body = "is too long (maximum is 1048576 characters)" })
  eq(other, {})
  by, other = model.field_errors({ message = "400 Bad Request: base Reference not found" }, { ref = "ref" })
  eq({ by, other }, { {}, { "base Reference not found" } })
  by = model.field_errors({ message = "409 Conflict: source_branch is invalid" }, { source_branch = "source" })
  eq(by, { source = "is invalid" })
  eq(model.message({ message = "403 Forbidden" }), "403 Forbidden")
  eq(model.message({ message = "400 Bad Request: Branch already exists" }), "Branch already exists")
end

T["model.date"] = function()
  eq({ model.date("2026-11-20"), model.date(" 20.11.2026 "), model.date("1.2.2026"), model.date("") }, { "2026-11-20", "2026-11-20", "2026-02-01", "" })
  eq({ model.date("tomorrow"), model.date("2026-13-01"), model.date("32.01.2026") }, {})
end

return T
