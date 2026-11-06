local H = require("tests.helpers")
local notes = require("gg.resources.notes")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local HOST, P, MP = H.TEST_HOST, "gitlab-org/cli", "my-group/my-project"
local ISSUE = { host = HOST, project = P, iid = 8666, noteable = "issue" }
local MR = { host = HOST, project = MP, iid = 12, noteable = "merge_request" }
local DID = "bbbb1750b37d513a43987b574953fceb50b03ce7"

local function with(base, extra)
  return vim.tbl_extend("force", base, extra)
end

T["issue discussions: GraphQL, paginated"] = function()
  local fake = H.fake({ "graphql/notes/issue_discussions.json" })
  local res = H.await(notes.discussions_all(ISSUE, { limit = 10, per_page = 3 }))
  eq(#res.items, 5)
  eq(res.truncated, false)
  eq(#fake:requests(), 2)
  eq(fake:requests()[1].variables, { fullPath = P, iid = "8666", first = 3 })
  eq(res.items[1].notes[1].system, true)
end

T["merge request discussions: REST, paginated, truncated"] = function()
  local fake = H.fake({ "rest/notes/mr_discussions.json" })
  local page = H.await(notes.discussions(MR, { per_page = 2 }))
  eq(#page.items, 2)
  eq(page.next_cursor, "o:2")
  eq(fake:last().path, "/api/v4/projects/my-group%2Fmy-project/merge_requests/12/discussions")
  fake:reset():load("rest/notes/mr_discussions.json")
  local res = H.await(notes.discussions_all(MR, { limit = 2, per_page = 2 }))
  eq(#res.items, 2)
  eq(res.truncated, true)
end

T["list: flat notes with a filter"] = function()
  local fake = H.fake({ "graphql/notes/mr_activity.json" })
  local page = H.await(notes.list({ host = HOST, project = P, iid = 4002, noteable = "merge_request", filter = "activity" }, { per_page = 3 }))
  eq(#page.items, 3)
  eq(page.items[2].system_action, "commit")
  eq(page.next_cursor:sub(1, 2), "g:")
  eq(fake:last().operation, "MrNotes")
  eq(fake:last().variables, { fullPath = P, iid = "4002", filter = "ONLY_ACTIVITY", first = 3 })
end

T["add: a diff comment fills the SHAs from the latest version"] = function()
  local fake = H.fake({ "rest/notes/write.json" })
  local d = H.await(notes.add(with(MR, { body = "Typo here", position = { new_path = "src/a.lua", new_line = 5 } })))
  eq(d.id, DID)
  eq(d.notes[1].position.head_sha, "33e2ee8579fda5bc36accc9c6fbd0b4fefda9e30")
  eq(fake:requests()[1].path, "/api/v4/projects/my-group%2Fmy-project/merge_requests/12/versions")
  eq(fake:requests()[2].json.position.old_path, "src/a.lua")
end

T["add: a response without notes is nil-safe"] = function()
  H.fake({ "rest/notes/write.json" })
  local d = H.await(notes.add({ host = HOST, project = MP, iid = 14, noteable = "issue", body = "Hello" }))
  eq(d.id, "cccc1750b37d513a43987b574953fceb50b03ce7")
  eq(d.notes, {})
end

T["reply, edit, delete"] = function()
  local fake = H.fake({ "rest/notes/write.json" })
  local issue = { host = HOST, project = MP, iid = 14, noteable = "issue" }
  local r = H.await(notes.reply(with(issue, { discussion_id = "cccc1750b37d513a43987b574953fceb50b03ce7", body = "Reply" })))
  eq({ r.id, r.body, r.discussion_id }, { 1302, "Reply", "cccc1750b37d513a43987b574953fceb50b03ce7" })
  local e = H.await(notes.edit(with(MR, { discussion_id = DID, note_id = 1300, body = "Typo fixed" })))
  eq(e.body, "Typo fixed")
  local e2 = H.await(notes.edit(with(issue, { note_id = 1302, body = "Edited" })))
  eq(e2.body, "Edited")
  eq(H.await(notes.delete(with(MR, { discussion_id = DID, note_id = 1300 }))), true)
  eq(fake:last().method, "DELETE")
end

T["set_resolved: REST for merge requests, GraphQL for issues"] = function()
  local fake = H.fake({ "rest/notes/write.json", "graphql/notes/toggle_resolve.json" })
  local d = H.await(notes.set_resolved(with(MR, { discussion_id = DID, resolved = true })))
  eq({ d.resolved, d.resolved_by.username }, { true, "user-1" })
  eq(fake:last().json, { resolved = true })
  local i = H.await(notes.set_resolved(with(ISSUE, { discussion_id = "e5d799cc2e9f9f179e3b06935055b38a9f3b5de1", resolved = true })))
  eq(i.resolved, true)
  eq(fake:last().operation, "DiscussionToggleResolve")
  local _, perr = H.await(notes.set_resolved(with(ISSUE, { discussion_id = "ffff", resolved = true })))
  eq({ perr.kind, perr.message }, { "validation", "Discussion is not resolvable" })
end

T["errors and validation"] = function()
  local fake = H.fake({ "rest/notes/write.json" })
  fake:add({ request = { operation = "IssueDiscussions" }, response = { body = { data = { project = { issue = vim.NIL } } } } })
  fake:add({ request = { path = "/api/v4/projects/my-group%2Fmy-project/merge_requests/12/discussions" }, response = { status = 403, body = { message = "403 Forbidden" } } })
  eq(select(2, H.await(notes.discussions(ISSUE))).kind, "not_found")
  eq(select(2, H.await(notes.discussions(MR))).kind, "forbidden")
  local _, sys = H.await(notes.reply({ host = HOST, project = MP, iid = 14, noteable = "issue", discussion_id = "dddd", body = "x" }))
  eq(sys.kind, "validation")
  local cases = {
    { notes.discussions, { host = HOST, project = P, iid = 1 } },
    { notes.discussions, with(ISSUE, { noteable = "epic" }) },
    { notes.add, with(ISSUE, { body = "x", position = { new_path = "a" } }) },
    { notes.add, with(MR, { body = "x", position = { new_line = 3 } }) },
    { notes.add, with(MR, { body = "x", position = { new_path = "a", bogus = 1 } }) },
    { notes.list, with(ISSUE, { filter = "system" }) },
    { notes.set_resolved, with(MR, { discussion_id = DID }) },
  }
  for i, c in ipairs(cases) do
    local _, err = H.await(c[1](c[2]))
    if not err or err.kind ~= "validation" then
      error(("case %d: expected validation, got %s"):format(i, vim.inspect(err)))
    end
  end
end

return T
