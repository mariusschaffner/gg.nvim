local H = require("tests.helpers")
local graphql = require("gg.graphql.client")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local function inline(op, text)
  return { operation = op, text = text or ("query " .. op .. " { x }") }
end

T["operation_name"] = function()
  eq(graphql.operation_name("issue_get"), "IssueGet")
  eq(graphql.operation_name("project_path"), "ProjectPath")
  eq(graphql.operation_name("mr_checks_full"), "MrChecksFull")
end

T["every query file defines its PascalCase operation"] = function()
  local bad = {}
  local files = H.files("lua/gg/graphql/queries", "%.graphql$")
  eq(#files > 0, true)
  for _, file in ipairs(files) do
    local name = vim.fs.basename(file):gsub("%.graphql$", "")
    local text, err = graphql.load(name)
    if not text then
      table.insert(bad, file .. ": " .. err.message)
    end
  end
  eq(bad, {})
end

T["load: unknown and invalid names are validation errors"] = function()
  eq(select(2, graphql.load("no_such_query")).kind, "validation")
  eq(select(2, graphql.load("../etc/passwd")).kind, "validation")
  local _, err = H.await(graphql.query(H.TEST_HOST, "no_such_query", {}))
  eq(err.kind, "validation")
end

T["query: POSTs query, variables and operationName to /api/graphql"] = function()
  local fake = H.fake({ "graphql/client/responses.json" })
  local data = H.await(graphql.query(H.TEST_HOST, "project_path", { ids = { "gid://gitlab/Project/42" } }))
  eq(data.projects.nodes[1].fullPath, "group/sub/repo")
  local rec = fake:last()
  eq(rec.method, "POST")
  eq(rec.path, "/api/graphql")
  eq(rec.json.operationName, "ProjectPath")
  eq(rec.json.query:find("query ProjectPath", 1, true) ~= nil, true)
  eq(rec.headers["Content-Type"], "application/json")
  eq(rec.headers["PRIVATE-TOKEN"], H.TEST_TOKEN)
end

T["errors only: graphql error, no partial data"] = function()
  H.fake({ "graphql/client/responses.json" })
  local data, err = H.await(graphql.query(H.TEST_HOST, inline("Broken")))
  eq(data, nil)
  eq(err.kind, "graphql")
  eq(err.message, "Field 'mergeRequest' doesn't exist on type 'Pipeline'")
  eq(err.details.partial, nil)
  eq(err.details.operation, "Broken")
end

T["partial data plus errors: an error that carries the data"] = function()
  H.fake({ "graphql/client/responses.json" })
  local data, err = H.await(graphql.query(H.TEST_HOST, inline("Partial")))
  eq(data, nil)
  eq(err.kind, "graphql")
  eq(err.message, "You don't have permission (and 1 more)")
  eq(err.details.partial, { project = { name = "repo" } })
  eq(#err.details.errors, 2)
  eq(err.details.errors[1].path, { "project", "secretThing" })
end

T["mutation payload errors are validation errors"] = function()
  H.fake({ "graphql/client/responses.json" })
  local data = H.await(graphql.query(H.TEST_HOST, inline("Mutate", "mutation Mutate { x }")))
  local err = graphql.payload_error(data.thingUpdate, "Mutate")
  eq(err.kind, "validation")
  eq(err.message, "Title can't be blank")
  eq(graphql.payload_error({ errors = {} }, "Mutate"), nil)
end

T["HTTP 401 on GraphQL is auth"] = function()
  H.fake({ "graphql/client/responses.json" })
  local _, err = H.await(graphql.query(H.TEST_HOST, inline("Unauth")))
  eq(err.kind, "auth")
  eq(err.status, 401)
end

T["require: null objects are not_found"] = function()
  H.fake({ "graphql/client/responses.json" })
  local data = H.await(graphql.query(H.TEST_HOST, inline("Missing")))
  local v, err = graphql.require(data, "project.issue", "issue g/r#1")
  eq(v, nil)
  eq(err.kind, "not_found")
  eq(err.message, "issue g/r#1 not found (or not visible to this token)")
  eq(graphql.require({ a = { b = 1 } }, "a.b"), 1)
end

T["is_schema_error"] = function()
  H.fake({ "graphql/client/responses.json" })
  local _, schema = H.await(graphql.query(H.TEST_HOST, inline("Broken")))
  eq(graphql.is_schema_error(schema), true)
  local _, partial = H.await(graphql.query(H.TEST_HOST, inline("Partial")))
  eq(graphql.is_schema_error(partial), false)
  local _, auth = H.await(graphql.query(H.TEST_HOST, inline("Unauth")))
  eq(graphql.is_schema_error(auth), false)
  local by_message = require("gg.core.errors").new("graphql", "x", { details = { errors = { { message = "Argument 'iid' doesn't accept argument" } } } })
  eq(graphql.is_schema_error(by_message), true)
end

T["page and paginate: three cursor pages"] = function()
  local fake = H.fake({ "transport/graphql_pages.json" })
  local q = inline("Things", "query Things($first: Int, $after: String) { project { things(first: $first, after: $after) { nodes { id } pageInfo { hasNextPage endCursor } } } }")
  local p1 = H.await(graphql.page(H.TEST_HOST, q, {}, "project.things", { per_page = 2 }))
  eq(#p1.items, 2)
  eq(p1.next_cursor, "g:c2")
  fake:reset():load("transport/graphql_pages.json")
  local all = H.await(graphql.paginate(H.TEST_HOST, q, {}, "project.things", { limit = 10, per_page = 2 }))
  eq(#all.items, 5)
  eq(all.truncated, false)
  eq(fake:requests()[2].variables, { first = 2, after = "c2" })
end

T["page: a null parent is not_found"] = function()
  H.fake({ "graphql/client/responses.json" })
  local _, err = H.await(graphql.page(H.TEST_HOST, inline("Missing"), {}, "project.issues", { what = "project g/r" }))
  eq(err.kind, "not_found")
end

T["project_path: paths resolve at once, IDs are looked up"] = function()
  local fake = H.fake({ "graphql/client/responses.json" })
  eq(H.await(graphql.project_path(H.TEST_HOST, "group/repo")), "group/repo")
  eq(#fake:requests(), 0)
  eq(H.await(graphql.project_path(H.TEST_HOST, 42)), "group/sub/repo")
  local _, err = H.await(graphql.project_path(H.TEST_HOST, "404"))
  eq(err.kind, "not_found")
  local _, verr = H.await(graphql.project_path(H.TEST_HOST, "norepo"))
  eq(verr.kind, "validation")
end

return T
