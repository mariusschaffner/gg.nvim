# gg.nvim build plan

Work top to bottom. An item is done when `make test` is green, its box is ticked, and it is committed as `<type>(<scope>): <id> <item name>` (conventional commits). Every item lists the files it touches, its acceptance criteria, and the test that proves it.

## Open questions (with the assumption taken)

Each entry gives the problem in INVENTORY.md (or a conflict with CLAUDE.md), then the assumption this plan builds on. Overrule any of them before or during execution.

1. **Models: atlas's types, or GitLab-native?** The INVENTORY "Decisions" table says gg returns the *same* domain objects the UI uses (`PullRequest`, `Issue`, …). Those types are provider-neutral leftovers from earlier providers: `state = "declined"`, `status_id`, `story_points`, `account_id`, `workspace`, pipeline states `STOPPED`/`INPROGRESS`. §6.10 #5 says gg will only ever serve GitLab. → **Assumption:** models are GitLab-native (`gg.Issue`, `gg.MergeRequest`, …) and carry every API-derived field atlas needs. Each resource item notes the non-obvious renames, so the atlas adapter is a pure mapping. UI-only fields and normalizations stay in atlas: the declined/draft MR state, `Open`, pipeline STOPPED/INPROGRESS, and `wf_state`.
2. **Caching.** The INVENTORY puts caching inside the plugin boundary, and §6.5 designs a tagged LRU plus a disk cache. CLAUDE.md's architecture has no cache module and forbids global mutable state, and the requested build order has no cache step. → **Assumption:** gg has no response cache in this plan, so every call goes to the network and consumers cache. The cache-related fixes (§5.5, §5.8, §6.8 #8–11, `force_load`) don't apply. A cache can be planned later as its own item.
3. **Client objects and module layout.** §6.1/§6.4 propose `glapi.new(opts) -> Client`, `http.lua`, `client.lua`, `cache/`, `resolve.lua` and `mappers/`. → **Assumption:** the CLAUDE.md layout wins and §6 is read only as required behavior. There are no client objects. Resources are stateless functions, `gg.<resource>.<fn>(args, opts) -> Task`, and every `args` carries an explicit `host`. Mappers live in `models/`, URL resolution in `context/`.
4. **Error kinds.** §6.3 uses `config|http|conflict|decode|cancelled`, which CLAUDE.md doesn't have. → **Assumption:** this mapping.

   | Case | Kind |
   |---|---|
   | 401, or a token function that fails | `auth` |
   | 403 | `forbidden` |
   | 404, or a GraphQL root that comes back `null` | `not_found` |
   | 400, 405, 406, 409, 422, bad arguments or config, mutation payload `errors` | `validation` |
   | 429 after retries | `rate_limited` |
   | curl exit 28, or a stall | `timeout` |
   | other curl exits | `network` |
   | a GraphQL `errors[]` | `graphql` |
   | 5xx, JSON decode failure, anything else | `unknown` |

   `status` and `details` are always kept.
5. **Cancellation.** Neither document says what happens after a cancel. → **Assumption:**
   - A cancelled task never calls its callbacks, and its process is killed.
   - Cancelling a `task.run` cancels the child it is awaiting, and the coroutine is never resumed.
   - When a task is cancelled from outside while a live coroutine awaits it, `await` returns `nil, err` with `kind = "unknown"` and `details.cancelled = true`. `gg.errors.is_cancelled(err)` tests for this.
6. **The "minimal endpoint list" isn't defined.** No section has that name. → **Assumption:** the list is the §6.7 catalogue minus what §6.10 removed:
   - Removed by §6.10 #6: the repository detail view (project statistics, README `file_raw`, tags, `delete_branch`, `issues_statistics`), the subscribe toggles, and adding reactions (`award_emoji`).
   - Kept: project search and the PR pipeline retry/cancel actions, which use the same endpoints as the pipeline detail view.
   - Added: a minimal `projects.get`, needed to turn a numeric ID into a path for GraphQL.
7. **Artifacts and registry aren't in the INVENTORY,** although CLAUDE.md lists them. → **Assumption:** minimal scope, built after every INVENTORY resource:
   - Artifacts: download the archive, or a single file, by job ID or by ref, streamed to a path or a callback.
   - Registry: container registry only, read-only (list repositories, list tags, get one tag).
   - Package registry is out of scope.
8. **GraphQL-first, while atlas reads mostly through REST.** → **Assumption:** each read uses GraphQL wherever docs.gitlab.com shows a field with the needed filters, and REST otherwise. REST is expected for diffs, job logs, downloads, branches, and the global `/issues` list (`Query.issues` is marked Experiment). Writes stay on REST unless only GraphQL supports them (work-item dates, resolving issue threads). Each resource module records its choice and the reason in a header comment.
9. **`opts.raw = true` (§6.6)** conflicts with "consumers only ever see mapped models." → **Assumption:** dropped.
10. **Nested GraphQL connections** (`assignees(first:100)`, labels, reviewers, stages, jobs, notes in a discussion) truncate silently today. → **Assumption:** top-level lists always paginate. Nested connections request `pageInfo.hasNextPage` and set `model.truncated.<field> = true`, so truncation is never silent.
11. **A numeric project ID on a GraphQL call** needs the full path first. → **Assumption:** one extra lookup per call (`projects(ids:)`), with no memo because there is no cache.
12. **Where the token comes from.** The token is a string or a function, and is read per request. `GITLAB_TOKEN` is used only for hosts listed in `config.hosts` that have no token of their own. `gitlab.com` is listed by default. Hosts that aren't listed get no token at all, so an env token can't leak to an arbitrary host parsed from a remote. Missing token → the request goes out without one, and a 401 becomes `auth` with a hint.
13. **Health check name.** CLAUDE.md says `:checkhealth gitlab_api`, but `lua/gg/health.lua` registers `:checkhealth gg`. → **Assumption:** `:checkhealth gg`.
14. **Relative URL roots and SSH host aliases** can't be resolved by a context module that depends on nothing. → **Assumption:** `context.parse(url, opts)` takes an optional `opts.hosts` table, in the same shape as `config.hosts` (`base_url` with a root, `aliases`). Callers pass `gg.config.get().hosts`.
15. **Fixtures "from real API responses."** Endpoints that need authentication, and all mutations, need a token. → **Assumption:**
   - Read endpoints are recorded from public gitlab.com projects, unauthenticated.
   - Auth-only endpoints and mutations use the example responses on docs.gitlab.com.
   - Everything is run through `scripts/sanitize_fixture.lua`, and `meta.source` records the origin. The maintainer can re-record later with a token.
16. **Testing the curl backend without network.** → **Assumption:** pure tests of the argv/stdin builder and the header parser, plus loopback tests against an in-process `vim.uv` TCP server on 127.0.0.1. That counts as no external network.
17. **Rate-limit state.** A shared limiter per host would be global mutable state. → **Assumption:** there is no shared limiter; retry and backoff are per request (policy in item 3.6).
18. **Redirects.** → **Assumption:** followed manually, up to 5. `PRIVATE-TOKEN` is sent only when the target's scheme, host and port equal the base URL's (fix §5.7).
19. **Version-skew fallbacks** (merge checks; the pipeline graph's `mergeRequest` field). → **Assumption:** retry only on a GraphQL schema/field error, per call, and remember nothing (§6.8 #12, #17).
20. **`wf_state`** (the `WF: <state>` label convention) is a team convention, not GitLab behavior. → **Assumption:** it stays in atlas; gg exposes the labels.
21. **Query parameters.** §6.10 #2 settles `labels` as a comma-separated string. → **Assumption:** generic array parameters use GitLab's `key[]=v` form (e.g. `iids[]`).
22. **Diffstat after `/changes` → `/diffs`** (§6.10 #7). → **Assumption:** derived from the paginated `/diffs` pages (it needs a limit):
   - Status comes from the `new_file`/`renamed_file`/`deleted_file` flags.
   - Counts come from the diff text.
   - Entries marked `too_large` or `collapsed` get `nil` counts.
23. **Features removed on the atlas side** (§6.10 #4/#5: `with_relationships`, `pr_template`, unused contract features) need no gg work. The issue `parent` field isn't modelled.
24. **The MR list "once per state, then merged."** → **Assumption:** one state per call (or `all`); merging is up to the consumer.
25. **`.graphql` files** are read synchronously once and memoized as immutable constants. That is treated as constant data, not mutable state.
26. **`:checkhealth`** runs synchronously, and CLAUDE.md bans blocking calls. → **Assumption:** health makes no network calls and spawns no processes. It reports whether curl is executable and checks the config.
27. **`mark_read` is an alias of `mark_done`** → only `todos.mark_done` exists.
28. **The old specs** (§6.9 "move with it") can't be copied ("do not copy its code"). → **Assumption:** the behaviors they assert are re-specified as new mini.test cases in the matching items.

## Definition of done (every item)

- Every public function and every model has LuaLS annotations.
- The public API never throws. Failures come back as a `gg.Error` through the Task.
- Tokens never appear in logs, errors, fixtures or test output.
- A resource item covers its model, its implementation (plus `.graphql` files), sanitized fixtures, and tests for success, pagination (when it has a list call) and error mapping. It also adds its re-export to `lua/gg/init.lua`.
- `make test` is green.

---

## 1. Scaffold and test harness

- [x] **1.1 scaffold: mini.test harness** — `chore(scaffold)`
  - Files: `Makefile` (`test`, `test-file FILE=`, and a `deps/mini.nvim` file target that clones a pinned mini.nvim tag), `tests/minimal_init.lua` (puts the repo and `deps/mini.nvim` on the rtp), `.gitignore` (`deps/`), `lua/gg/init.lua` (empty facade), `.luarc.json`.
  - Acceptance: `make test` runs `nvim --headless --noplugin -u tests/minimal_init.lua` with `MiniTest.run()`, finds `tests/**/test_*.lua`, reports 0 cases and exits 0. A temporary failing case makes it exit non-zero (checked by hand, not committed). It works from mingw make on Windows and from sh.
  - Test: `make test` itself, on the empty suite.
- [x] **1.2 guard tests for the conventions** — `test(scaffold)`
  - Files: `tests/helpers.lua` (repo file walker), `tests/unit/test_architecture.lua`.
  - Acceptance: these checks scan `lua/gg/**`:
    - Layering: core < config < transport < graphql/rest < resources < health < init. context and models require nothing from gg outside their own folder.
    - No `vim.wait`, no `:wait(`, no `vim.fn.system`, no `io.popen` or `os.execute`, no `"git"` argv.
    - Every `M.fn` has `---@` annotations, and every `models/*.lua` declares a `---@class gg.*`.
  - Test: `tests/unit/test_architecture.lua` (vacuous now, and it binds every later item).

## 2. core

- [x] **2.1 core/task: async tasks with cancellation** — `feat(core)`
  - Files: `lua/gg/core/task.lua`, `tests/helpers.lua` (`await(task, ms)` built on `vim.wait`, for tests only), `tests/unit/core/test_task.lua`.
  - API:
    - `task.new(producer(resolve, reject, on_cancel))`
    - `:on_done(cb)`, `:cancel()`, `:await()`, `:is_done()`, `:is_cancelled()`
    - `task.run(fn)`, `task.resolved(v)`, `task.failed(err)`, `task.all(tasks)`
  - Acceptance:
    - A task settles exactly once.
    - Callbacks always go through `vim.schedule`, even when the task has already settled.
    - `cancel` is idempotent, runs the producer's cancel hook once, and suppresses callbacks.
    - `await` outside a coroutine returns `nil, validation error` and doesn't throw.
    - A Lua error inside `task.run` becomes an `unknown` error.
    - Cancelling `run` cancels the awaited child.
    - `all` keeps result order, fails on the first error and cancels the rest.
    - The external-cancel case follows open question 5.
  - Test: `test_task.lua`, one case per criterion.
  - Note (2026-11-06): task needs the error constructor, so this item also creates a minimal `core/errors.lua` (`new`, `is`, `cancelled`, `is_cancelled`, `wrap`). Item 2.2 completes it.
- [x] **2.2 core/errors and redaction** — `feat(core)`
  - Files: `lua/gg/core/errors.lua`, `lua/gg/core/redact.lua`, `tests/unit/core/test_errors.lua`, `test_redact.lua`.
  - Acceptance:
    - `errors.new(kind, message, {status, details})` accepts only the CLAUDE.md kinds; an invalid kind becomes `unknown` with `details.invalid_kind`.
    - `errors.is`, `errors.is_cancelled` and `__tostring` work.
    - Messages and details are redacted deeply.
    - `redact.string/value(v, secrets?)` masks: `glpat-`/`gl*-` tokens, `PRIVATE-TOKEN:` and `Authorization:` values, the `private_token`/`job_token`/`access_token` query parameters, URL userinfo, sensitive keys (`token`, `private-token`, `authorization`, `password`), and any exact secret it is passed.
  - Test: table-driven cases in both files.
- [x] **2.3 core/log** — `feat(core)`
  - Files: `lua/gg/core/log.lua`, `tests/unit/core/test_log.lua`.
  - Acceptance:
    - Levels: trace, debug, info, warn, error, off; the default is warn.
    - `log.configure({level, sink})`. The default sink appends asynchronously (`vim.uv`) to `stdpath("log")/gg.log`.
    - Fields are formatted lazily and always pass through redact.
    - A failing sink is caught and never throws.
  - Test: `test_log.lua` with a capture sink: level filtering, redaction, sink errors.

## 3. Config and transport

- [x] **3.1 config: defaults, schema, validation** — `feat(config)`
  - Files: `lua/gg/config.lua`, `tests/unit/test_config.lua`.
  - Schema:
    - `hosts[name] = { base_url, token = string|fun():string, aliases = {} }`. The default is `{ ["gitlab.com"] = { base_url = "https://gitlab.com" } }`.
    - `timeout = { connect = 10, total = 60, stall = 30 }`
    - `retry = { max_attempts = 3, base_delay_ms = 500, max_delay_ms = 30000, max_retry_after_s = 60 }`
    - `curl = { cmd = "curl" }`, `transport = { backend = "curl" | table }`, `log = { level, sink }`
  - Acceptance:
    - `setup(opts)` returns `true`, or `false, validation err`, naming the key path. On failure the previous config is kept.
    - `get()` returns a deep copy. `host(name)` returns the effective settings: global settings with the host's overlaid, host names lowercased, and a derived `https://<host>` for hosts that aren't listed.
    - Tokens never appear in validation messages.
  - Test: `test_config.lua`: defaults, merging, unknown keys and wrong types, deep-copy isolation, token absent from errors.
- [x] **3.2 transport/http and the curl backend** — `feat(transport)`
  - Files: `lua/gg/transport/http.lua` (request pipeline: URL, headers, manual redirects, decoding), `lua/gg/transport/backends/curl.lua`, `tests/unit/transport/test_curl.lua`, `test_http.lua`.
  - Acceptance:
    - curl runs through `vim.system({curl, "--config", "-", …})`. Headers, the token and the URL go in the stdin config, escaped. The body is a temp file passed with `--data-binary @file`. Headers are captured with `--dump-header <tmp>`, and the status with `-w`.
    - `--connect-timeout` and `--max-time` come from config. Streaming requests use `--speed-limit/--speed-time` (stall) instead of a total timeout.
    - `output = path` writes to `path.part` and renames it on success. `on_chunk` streams stdout.
    - `Content-Type` is sent only with a body.
    - Cancel kills the process and removes the temp files.
    - Redirects follow open question 18.
    - Exit 28 → `timeout`; other exits → `network`.
  - Test: `test_curl.lua`:
    - The builder: the token is absent from argv and present in stdin.
    - Quoting of `"` and `\`.
    - Parsing of multi-block header dumps.
    - Exit-code mapping.
    - A loopback `vim.uv` server: GET, JSON body, streaming to a file, cancel (no callback, no temp files left).

    `test_http.lua` drives an inline stub backend: same-origin redirect keeps the token, cross-origin drops it, more than 5 redirects → `network`.
- [x] **3.3 fake backend and fixture tooling** — `feat(transport)`
  - Files: `lua/gg/transport/backends/fake.lua`, `scripts/sanitize_fixture.lua`, `tests/fixtures/README.md` (format and sanitization rules), `tests/unit/transport/test_fake.lua`, `tests/unit/test_fixtures.lua`.
  - Fixture format: JSON `{ meta = {source, notes}, request = {method, path, query} | {operation, variables}, response = {status, headers, body | body_base64} }`. A fixture file may hold an array, for page sequences.
  - Acceptance:
    - REST requests match by method, path and order-insensitive query. GraphQL requests match by operation name and a subset of the variables.
    - Pages are served in sequence. Requests are recorded for assertions.
    - Failures can be injected: a status, a timeout or network failure, a delay.
    - An unmatched request returns an `unknown` error that lists the closest fixtures.
    - Streaming is supported: the fake writes to the output path, or calls `on_chunk` in chunks.
    - The fake can be used by consumers' tests.
  - Test: `test_fake.lua`. `test_fixtures.lua` scans every fixture and fails on token patterns, emails outside `example.com`, hosts other than `gitlab.example.com` and `gitlab.com`, and `name`/`username` values outside the sanitized patterns.
- [x] **3.4 transport/auth** — `feat(transport)`
  - Files: `lua/gg/transport/auth.lua`, `tests/unit/transport/test_auth.lua`.
  - Acceptance:
    - Token order: the host's config `token` (a string, or a function called per request) → `GITLAB_TOKEN` (listed hosts only) → none. It is sent as `PRIVATE-TOKEN`.
    - A token function that errors gives `auth`.
    - A 401 with no token adds a hint naming the host.
    - The token is passed as an exact secret to redaction in that request's scope.
  - Test: `test_auth.lua` with the fake backend:
    - Each source in turn.
    - A host that isn't listed gets no env token.
    - A failure whose body echoes the token leaves the token out of the error, out of `vim.inspect(err)` and out of the captured log.
- [x] **3.5 HTTP error mapping** — `feat(transport)`
  - Files: `lua/gg/transport/http.lua`, `tests/unit/transport/test_error_mapping.lua`.
  - Acceptance:
    - Statuses map as in open question 4.
    - The message comes from the body's `message` (a string or a field table), `error`, `error_description`, or the status text.
    - `details` holds the method, the redacted URL, `request_id` (`x-request-id`), and a redacted body truncated to 2 KB.
    - A 2xx body with a `message` field is **not** an error (fix §5.6).
    - 204 or an empty 2xx → `nil` body. Invalid JSON → `unknown`.
  - Test: table-driven over 400/401/403/404/405/409/422/429/500/502/503, curl exits 6/7/28/35, bad JSON, and a 2xx with `message`.
- [x] **3.6 rate limit and backoff** — `feat(transport)`
  - Files: `lua/gg/transport/ratelimit.lua`, `tests/unit/transport/test_ratelimit.lua`.
  - Acceptance:
    - 429 → wait `Retry-After`, or `RateLimit-Reset` minus now, capped at `max_retry_after_s`. This applies to every method, because a 429 means the request wasn't processed.
    - GET and HEAD also retry on 502/503/504 and network errors, with exponential backoff and full jitter.
    - Stop after `max_attempts`, then return `rate_limited` with `details.retry_after`.
    - Waits use `vim.uv` timers and can be cancelled. The clock and the random source can be injected.
    - `RateLimit-*` headers are parsed into `response.rate_limit` and logged at debug.
  - Test: `test_ratelimit.lua` with the fake and an injected clock:
    - 429 then 200 → 2 requests, with the expected delay.
    - A POST and a 503 → no retry.
    - The attempts run out → `rate_limited`.
    - Cancel during backoff → no further request.
- [x] **3.7 pagination: offset, keyset, GraphQL cursors** — `feat(transport)`
  - Files: `lua/gg/transport/pagination.lua`, `tests/unit/transport/test_pagination.lua`.
  - Acceptance:
    - Link header parser.
    - Offset: `x-next-page`, falling back to `Link rel=next`.
    - Keyset: follow `Link rel=next` as given. A next link to another origin → `validation`.
    - GraphQL: `pageInfo { hasNextPage endCursor }` at a connection path.
    - The cursor is an opaque string. `per_page` defaults to 100 and is capped at 100.
    - `collect(fetch_page, args, {limit, on_page})`: `limit` is required (missing or ≤ 0 → `validation`). It stops fetching once the limit is reached and returns `{items, truncated}`; `truncated = true` when more items existed.
  - Test: `test_pagination.lua`: three offset pages; keyset via `Link`; three GraphQL pages; truncation at the limit (no extra request); an empty `x-next-page` ends; a missing limit; a cross-origin link.

## 4. Clients

- [x] **4.1 rest client** — `feat(rest)`
  - Files: `lua/gg/rest/client.lua`, `tests/unit/rest/test_client.lua`.
  - Acceptance:
    - `rest.request(host, method, path, {query, body, headers, output, on_chunk}) -> Task`.
    - `rest.page(host, path, {query, per_page, cursor, pagination = "offset"|"keyset"}) -> Task<{items, next_cursor}>`.
    - URL = the host's `base_url` (relative roots kept) + `/api/v4` + path.
    - `rest.project(id_or_path)`: integers pass through; strings are fully encoded (`/` → `%2F`). `rest.seg(x)` encodes any other segment.
    - `rest.query(t)`: keys and values encoded, keys sorted, arrays as `key[]=`.
    - Decoding uses `luanil`, so JSON `null` becomes `nil`.
  - Test: `test_client.lua`: encoding of `group/sub/repo`, spaces and unicode; numeric IDs; query keys sorted and encoded; relative root `https://h/gitlab`; a body sets `Content-Type`; 204 → `nil`.
- [x] **4.2 graphql client and query files** — `feat(graphql)`
  - Files: `lua/gg/graphql/client.lua`, `lua/gg/graphql/queries/` (`project_path.graphql`), `tests/unit/graphql/test_client.lua`.
  - Acceptance:
    - `graphql.query(host, name, variables)` loads `queries/<name>.graphql`; the operation name equals the PascalCase file name. It POSTs `{query, variables, operationName}` to `<base>/api/graphql`.
    - A non-empty `errors[]` → a `graphql` error with `details.errors` (message, path, extensions) and `details.partial = data` when `data` is non-null. Partial data is never dropped and never returned as success.
    - `graphql.require(data, "project.issue")` → `not_found` on `nil`.
    - Payload `errors` on a mutation → `validation`.
    - `graphql.is_schema_error(err)` (for fallbacks).
    - `graphql.paginate(host, name, vars, connection_path, {limit})` builds on 3.7.
    - `graphql.project_path(host, id_or_path)` follows open question 11.
    - A missing query file → `validation`, not a throw.
  - Test: `test_client.lua`: success; errors only; partial data plus errors (`details.partial` present); payload errors; 401 → `auth`; `null` project → `not_found`; three-page cursor pagination; schema-error detection; operation-name check for every file in `queries/`.
  - Note (2026-11-06): `query`/`page` also accept an inline `{ operation, text }`, so the generic client tests don't ship test-only `.graphql` files. Resources always use query files.

## 5. context

- [x] **5.1 context: remote URLs** — `feat(context)`
  - Files: `lua/gg/context/remote.lua`, `lua/gg/context/init.lua`, `tests/unit/context/test_remote.lua`.
  - Acceptance:
    - Pure. `parse(url, {hosts?})` returns a `gg.Remote { host, port?, scheme, project, base_url }`, or `nil, {kind="validation", …}` (a plain table of the same shape).
    - Supported forms:
      - scp-style `git@host:group/sub/repo.git`
      - `ssh://git@host:2222/…`, where the port is not part of `host`, and `base_url` comes from `hosts`, else `https://host`
      - `https://host:8443/…`, where the port is kept in `base_url`
      - `http://` and `git://`
      - credentials in the URL, which are stripped and never returned
      - a relative root and aliases, via `hosts`
      - subgroups, `.git` or no `.git`, trailing slashes, uppercase hosts, IPv6 literals
    - Rejected: a single-segment path, `file://`, local paths, empty input.
  - Test: `test_remote.lua`, a table of about 25 URLs, with an exact expected table per row.
- [x] **5.2 context: web URLs and short references** — `feat(context)`
  - Files: `lua/gg/context/web.lua`, `tests/unit/context/test_web.lua`.
  - Acceptance:
    - `parse_web_url(url, {hosts?})` returns `{host, project, kind, iid|id}` for `/-/issues/N`, `/-/merge_requests/N[/diffs|/pipelines…]`, `/-/pipelines/N`, `/-/jobs/N`, `/-/milestones/N`, `/-/work_items/N`, and the bare project URL. Query strings and fragments are ignored.
    - `parse_ref("#12" | "!3" | "group/repo#12" | "group/repo!3", default_project?)`.
    - A relative root is respected.
  - Test: `test_web.lua`, table-driven, including rejects (an unknown `/-/` kind, a trailing segment that isn't a number).

## 6. Resources

Every item follows the same pattern:
- Files: `lua/gg/models/<model>.lua` (with `from_rest`/`from_graphql` mappers), `lua/gg/resources/<name>.lua`, `lua/gg/graphql/queries/<op>.graphql`, `tests/fixtures/{rest,graphql}/<name>/*.json`, `tests/unit/models/test_<model>.lua`, `tests/unit/resources/test_<name>.lua`, and the `lua/gg/init.lua` re-export.
- Signatures:
  - `fn(args, opts?) -> Task`, where `args.host` is required and `args.project` is a path or a numeric ID.
  - A list call returns `Task<gg.Page<T>>` (`{items, next_cursor}`), with `opts = {per_page, cursor}`.
  - `<fn>_all(args, {limit, per_page?, on_page?})` returns `Task<{items, truncated}>`.
  - A mutation returns the updated model, or `true`.
- Tests always cover:
  - success: the mapped model, checked field by field
  - request shape: encoded path, query, GraphQL variables
  - pagination: `_all` over 2+ fixture pages, and truncation at the limit
  - errors: 404 → `not_found`, 403 → `forbidden`, GraphQL `errors` → `graphql`, mutation payload errors → `validation`
- The defaults are today's limits (§6.6).
- Unless an item says otherwise: **Files** = the list above, **Acceptance** = the functions listed below behave as described, with the documented backend, and **Test** = `tests/unit/resources/test_<name>.lua` plus `tests/unit/models/test_<model>.lua` with the cases above, and any extra cases the item names.

- [x] **6.1 issues** — `feat(issues)`
  - Models:
    - `gg.Issue`: id, iid, project, title, description?, state, type, confidential, author, assignees, labels, milestone?, weight?, due_date?, web_url, references, user_notes_count, created_at, updated_at, closed_at?, subscribed?, truncated?
    - shared: `gg.User` (id, username, name, avatar_url?, web_url?), `gg.Label` (id?, name, color, text_color?, description?), `gg.MilestoneRef` (id, iid?, title, state?, web_url?), and `models/gid.lua` (`tail`, `build`)
    - atlas renames: story_points ← weight; status ← state; duedate ← due_date; comment_count ← user_notes_count; reporter ← author; key ← `project#iid`.
  - Functions and backends:
    - `list`/`list_all`: GraphQL `project.issues` or `group.issues`; REST `/issues` when neither project nor group is given (open question 8). Filters: state, labels (comma-separated), milestone, assignee/author username, search, iids, scope, order_by/sort mapped to GraphQL `sort`. Default per_page 50.
    - `get` (GraphQL details) and `by_iids`.
    - `create` and `update` (REST). `update` covers title, description, state_event, labels, add_labels/remove_labels, and assignee_ids/milestone_id, where clearing follows the docs.
    - The old `search_issues_picker` becomes `list({scope="all", search=…}, {per_page=30})`.
  - Also adds `tests/unit/test_public_api.lua`: every exported resource function, called with `nil`, `{}` or wrong types, returns a Task that resolves to `validation` and never throws. It covers every later resource automatically.
  - Note (2026-11-06): the GraphQL reference pages on docs.gitlab.com are too large to read in full. GraphQL field, argument and enum names are therefore checked against gitlab.com's own published schema (introspection, unauthenticated). REST parameters are checked against docs.gitlab.com/api/issues. Fixtures are real responses from `gitlab-org/cli` and `gitlab-org/quality`, plus docs examples for REST and errors. Also added: `#import "<fragment>"` support in the GraphQL loader (`graphql/fragments/`), and `resources/common.lua` (argument validation, the list/list_all pair).
- [x] **6.2 labels** — `feat(labels)`
  - `list`/`list_all` (GraphQL `project.labels`, with `searchTerm` and `includeAncestorGroups = true`; default per_page 100) → `gg.Label`.
- [x] **6.3 users** — `feat(users)`
  - `current` (GraphQL `currentUser`).
  - `project_members`/`_all` (GraphQL `project.projectMembers(search)`, direct and inherited; default 100) → `gg.User`.
  - Replaces the two `/user` copies and the three members copies (§5.4 #3, #4).
- [x] **6.4 work_items (issue dates)** — `feat(work_items)`
  - `dates({host, project, iid})` → `gg.WorkItemDates {work_item_id, start_date?, due_date?}` (GraphQL `namespace.workItem` widgets).
  - `update_dates({…, start_date?, due_date?})`: `false` clears a date; the work-item ID is looked up when it isn't passed; uses the `workItemUpdate` mutation.
  - Pagination: not applicable (stated in the spec).
- [x] **6.5 branches** — `feat(branches)`
  - `list`/`list_all` (REST `/repository/branches` with `search`; GraphQL only exposes names, with offset paging; default 100) → `gg.Branch {name, commit_sha?, default, protected, merged, web_url?}`.
  - `create({branch, ref})`.
  - `related_to_issue({iid})` = `list({search = "^<iid>-"})`. This fixes the "misses past 100" bug (§5.2).
- [x] **6.6 merge_requests** — `feat(merge_requests)`
  - Model `gg.MergeRequest`: id, iid, project, title, description?, state, draft, author, assignees, reviewers, labels, milestone?, source_branch, target_branch, source/target_project_id, sha?, diff_refs?, merge_status?, detailed_merge_status?, has_conflicts?, user_notes_count, should_remove_source_branch?, squash?, web_url, references, timestamps, subscribed?, truncated?
    - atlas renames: state open/declined/draft ← state + draft; destination.branch ← target_branch; comments_count ← user_notes_count; link.html ← web_url; repo_full_name ← project.
  - Functions and backends:
    - `list`/`list_all`: GraphQL `project.mergeRequests` or `group.mergeRequests`; when neither is given, the scopes `created_by_me`, `assigned_to_me` and `review_requests` (GraphQL `currentUser.*MergeRequests` if the docs confirm, else REST `/merge_requests`). Default per_page 50.
    - `by_iids` and `get` (details).
    - `create`, `update` (title, description, state_event, target_branch, labels, milestone, assignees, reviewers, remove_source_branch, draft per the docs) and `merge` (REST). 405/406/409/422 → `validation`, with GitLab's message.
    - `related_to_issue({project, iid})`/`_all` (default 20).
  - Note (2026-11-06):
    - The scopes use GitLab's REST names: `created_by_me`, `assigned_to_me`, `reviews_for_me` (GraphQL `currentUser.*MergeRequests`), and `all` (REST).
    - docs.gitlab.com shows no `draft` parameter for REST create or update, so draft status goes through the GraphQL `mergeRequestSetDraft` mutation.
- [x] **6.7 milestones** — `feat(milestones)`
  - Model `gg.Milestone`: id, iid, project/group, title, description, state, start_date, due_date, expired?, web_url, created_at, updated_at.
  - `list`/`list_all` (`state = "active"` by default, GraphQL), `get`, `issues`/`_all` → `gg.Issue`, `merge_requests`/`_all` → `gg.MergeRequest`.
  - `create` and `update` (title, description, dates, state_event; REST).
  - `web_url` comes from the API, never from `base_url .. webPath` (fix §6.8 #19).
- [x] **6.8 mr_changes** — `feat(mr_changes)`
  - `commits`/`_all` (GraphQL `mergeRequest.commits`; default 100) → `gg.Commit`.
  - `diffs`/`_all` (REST `/diffs`, with `unidiff`) → `gg.DiffFile`.
  - `diffstat({…, limit})` → `gg.DiffStat[]`, derived as in open question 22, with a pure helper in `models/diff.lua`.
  - `versions`/`latest_version` → `gg.MergeRequestVersion` (diff refs).
- [x] **6.9 mr_checks** — `feat(mr_checks)`
  - `get` → `gg.MergeChecks`: draft, detailed_merge_status, discussions_resolved, has_conflicts, head_pipeline_status?, approved?, resolvable/resolved discussions?, checks? (`mergeabilityChecks` if the docs confirm it).
  - The full query falls back to the base query **only** on a schema error. An auth or network error doesn't fall back (fix §5.6, §6.8 #12).
  - Pagination: not applicable.
- [x] **6.10 notes (issues and MRs)** — `feat(notes)`
  - `args.noteable = "issue" | "merge_request"`.
  - Reads:
    - `discussions`/`_all` (GraphQL, paginated; fixes the unpaginated issue discussions) → `gg.Discussion {id, resolvable, resolved, resolved_by?, resolved_at?, notes, truncated?}`
    - `list`/`_all` (flat notes, `filter = all|comments|activity`) → `gg.Note {id, discussion_id?, body, author, system, system_note_icon_name?, internal?, created_at, updated_at, resolvable?, resolved?, position?, outdated?, reactions?, url?}`
  - Writes:
    - `add`: REST `/discussions`. An MR `position` without diff refs uses `mr_changes.latest_version`. The response is read nil-safely (fix §5.6 `notes[1]`).
    - `reply`, `edit`, `delete` (IDs always encoded).
    - `set_resolved`: MR via REST; issues via GraphQL `discussionToggleResolve`.
  - The outdated-comment and root-only resolution rules are re-specified from `mapper_spec`.
  - Note (2026-11-06): merge request `discussions` use REST (`/merge_requests/:iid/discussions`), not GraphQL. The GraphQL `Note` type has no original position, and outdated diff threads need one. Atlas used REST here too. Issue discussions and the flat `list` use GraphQL. REST MR discussions need a token, so their fixtures are docs examples. The sanitizer now also rewrites every `@mention`, and `test_fixtures.lua` checks this.
- [ ] **6.11 reviews** — `feat(reviews)`
  - `reviewers` (GraphQL reviewers, `approvedBy` and `reviewState`) → `gg.Reviewer {user, review_state?, approved}`. Approvers who aren't reviewers come back as `role = "participant"`.
  - `drafts`/`_all`, `create_draft` (position, `in_reply_to_discussion_id`), `edit_draft`, `delete_draft` → `gg.DraftNote`.
  - `discard_drafts`: collect with a limit, then delete one by one. It stops at the first error, and `err.details.deleted` says how many were deleted.
  - `publish({note?, reviewer_state?})` (`bulk_publish`; the parameters are checked against the docs) and `approve({sha?})`.
- [ ] **6.12 todos** — `feat(todos)`
  - `list`/`_all` (GraphQL `currentUser.todos`, state pending by default) → `gg.Todo {id, action, target_type, target {iid?, title?, web_url?}, body, state, project?, author, created_at}`.
  - `mark_done({id})`.
- [ ] **6.13 pipelines** — `feat(pipelines)`
  - Model `gg.Pipeline`: id, iid, project, status (lowercase GitLab status), ref, sha, short_sha, source?, user?, merge_request?, timestamps, duration?, queued_duration?, web_url, commit_title?, total_jobs?, stages?
  - `list`/`_all` for a project (ref, status, source, username, sha) or an MR (`mr_iid`), GraphQL; default 50; nested stages carry truncated flags.
  - `get` (GraphQL by ID, so no REST lookup first).
  - `graph` → `gg.Pipeline`, with stages → groups → `gg.Job`. Stage order and job flags are kept. The `mergeRequest` field is dropped on a schema error (open question 19). The query is checked against the complexity limit of 250.
  - `retry` and `cancel` (REST).
- [ ] **6.14 jobs** — `feat(jobs)`
  - Model `gg.Job`: id, name, stage, status, allow_failure, manual, playable?, retryable?, cancelable?, duration?, queued_duration?, timestamps, web_url, ref?, pipeline_id?, user?, artifacts?
  - `list`/`_all` for a pipeline (GraphQL `pipeline.jobs` if it covers the fields, else REST; default 100), and `get`.
  - `trace({id, output | on_chunk, offset?})`:
    - It never buffers the log; calling it with neither `output` nor `on_chunk` → `validation`.
    - `offset` sends `Range: bytes=N-`. A 206 appends. A 200 means the server ignored the range, and the result says `range_ignored = true`. A 416 means no new bytes.
    - It returns `{bytes, range_ignored?}`.
  - `retry`, `cancel`, `play`.
- [ ] **6.15 projects** — `feat(projects)`
  - `search({query, membership?})`/`_all` (default 20, ordered by last activity) → `gg.Project {id, name, path, full_path, description?, default_branch?, visibility?, web_url, last_activity_at?, archived?}`.
  - `get({project})` (minimal; open question 6).
- [ ] **6.16 artifacts** — `feat(artifacts)`
  - `download({job_id, output})`, `download_file({job_id, artifact_path, output | on_chunk})`, `download_ref({ref, job, output})`, `download_ref_file(…)` → `gg.Download {path?, bytes}`.
  - Every call streams. Redirects to a CDN or object storage drop the token (checked with fake redirect fixtures). There is no total timeout, only the stall timeout. 404 → `not_found`. A partial file is removed on failure or cancel.
- [ ] **6.17 registry (container)** — `feat(registry)`
  - `repositories`/`_all` → `gg.ContainerRepository {id, name, path, location, tags_count?, created_at}`.
  - `tags`/`_all` → `gg.ContainerTag {name, path, location, digest?, revision?, total_size?, created_at?}`, using REST keyset (a documented keyset endpoint), so it exercises keyset end to end.
  - `tag({repository_id, name})`.
  - GraphQL wherever the docs show the needed fields.

## 7. Health and documentation

- [ ] **7.1 health: `:checkhealth gg`** — `feat(health)`
  - Files: `lua/gg/health.lua`, `tests/unit/test_health.lua`.
  - Acceptance:
    - Reports Neovim ≥ 0.10, whether curl is executable, and whether the config validates.
    - Per host: the `base_url` scheme (warns on `http://`) and the token source (config, function, `GITLAB_TOKEN` or none → warn), never the value.
    - Warns when the backend isn't curl. Reports the log level.
    - No network, no spawned processes (open question 26).
  - Test: `test_health.lua` stubs `vim.health.*` and checks the messages per scenario, and that the token text never appears.
- [ ] **7.2 public facade, README and `:help gg`** — `docs`
  - Files: `lua/gg/init.lua` (final re-exports: setup, config.get, task, errors, context, every resource, `testing.fake_backend`), `README.md`, `doc/gg.txt`, `tests/unit/test_docs.lua`.
  - Acceptance: README and help cover:
    - install, requirements and setup schema
    - multi-host and context parsing
    - Task usage: callback, await, cancel
    - the error kinds
    - pagination: list vs `_all`, and the required limit
    - every resource function, with args and return model
    - consumers testing with the fake backend
    - security notes
  - Test: `test_docs.lua` runs `:helptags` on a temp copy of `doc/` (no errors, no duplicate tags), and checks that every function exported by `require("gg")` has a `*gg.<resource>.<fn>()*` tag.

## Not in this plan

- A response cache (open question 2).
- CI workflows, stylua and selene.
- The atlas adapters and the porting of atlas.
- The package registry.
- OAuth or Bearer tokens.
