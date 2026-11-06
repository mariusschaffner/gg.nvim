local H = require("tests.helpers")
local fake = require("gg.transport.backends.fake")
local note = require("gg.models.note")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function rest_discussions()
  local out = {}
  for _, page in ipairs(fake.read(H.path("tests/fixtures/rest/notes/mr_discussions.json"))) do
    vim.list_extend(out, page.response.body)
  end
  return out
end

T["REST: resolution data only on the root of a resolved thread"] = function()
  local d = note.discussion_from_rest(rest_discussions()[1])
  eq(d.id, "6a9c1750b37d513a43987b574953fceb50b03ce7")
  eq({ d.resolvable, d.resolved, d.resolved_by.username, d.resolved_at }, { true, true, "user-2", "2018-03-05T10:00:00.000Z" })
  local root, reply = d.notes[1], d.notes[2]
  eq({ root.resolvable, root.resolved, root.resolved_by.username }, { true, true, "user-2" })
  eq({ reply.resolvable, reply.resolved, reply.resolved_by, reply.resolved_at }, { nil, nil, nil, nil })
  eq(root.discussion_id, d.id)
  eq(root.position, {
    base_sha = "b5d6e7b1613fca24d250fa8e5bc7bcc3dd6002ef",
    start_sha = "7c9c2ead8a320fb7ba0b4e234bd9529a2614e306",
    head_sha = "4803c71e6b1833ca72b8b26ef2ecd5adc8a38031",
    old_path = "package.json",
    new_path = "package.json",
    old_line = 27,
    new_line = 27,
    position_type = "text",
    line_range = root.position.line_range,
  })
  eq(root.position.line_range.start.new_line, 10)
  eq(root.outdated, nil)
end

T["REST: an individual comment is not resolvable"] = function()
  local d = note.discussion_from_rest(rest_discussions()[2])
  eq({ d.individual_note, d.resolvable, d.resolved }, { true, false, false })
  eq(d.notes[1].body, "LGTM")
end

T["REST: outdated notes keep their original multi-line position"] = function()
  local d = note.discussion_from_rest(rest_discussions()[3])
  local n = d.notes[1]
  eq(n.outdated, true)
  eq(n.position.new_path, "src/a.lua")
  eq(n.position.line_range.start.new_line, 4)
  eq(n.position.line_range["end"].new_line, 5)
  eq({ d.resolved, d.resolved_by }, { false, nil })
end

T["REST: a discussion without notes is nil-safe"] = function()
  local d = note.discussion_from_rest({ id = "x", individual_note = false })
  eq(d.notes, {})
  eq(d.resolvable, false)
end

T["GraphQL: real gitlab.com issue thread, root-only resolution"] = function()
  local pages = fake.read(H.path("tests/fixtures/graphql/notes/issue_discussions.json"))
  local nodes = pages[2].response.body.data.project.issue.discussions.nodes
  local d = note.discussion_from_graphql(nodes[2], { origin = "https://gitlab.com" })
  eq(d.id, "e5d799cc2e9f9f179e3b06935055b38a9f3b5de1")
  eq(d.resolvable, true)
  eq(#d.notes, 3)
  eq(d.notes[1].discussion_id, d.id)
  eq(d.notes[2].resolvable, nil)
  eq(type(d.notes[1].id), "number")
  eq(d.notes[1].url:find("https://gitlab.com/", 1, true), 1)
  eq(d.truncated, nil)
end

T["GraphQL: system notes, reactions"] = function()
  local pages = fake.read(H.path("tests/fixtures/graphql/notes/mr_activity.json"))
  local n = note.note_from_graphql(pages[1].response.body.data.project.mergeRequest.notes.nodes[1])
  eq(n.system, true)
  eq(n.system_note_icon_name, "user")
  eq(n.system_action, "assignee")
  local t = fake.read(H.path("tests/fixtures/graphql/notes/toggle_resolve.json"))[1].response.body.data.discussionToggleResolve.discussion
  local d = note.discussion_from_graphql(t)
  eq(d.notes[1].reactions, { { name = "thumbsup", username = "user-1" } })
  eq(d.notes[1].resolved_by.username, "user-1")
  eq(d.notes[2].resolved_by, nil)
end

return T
