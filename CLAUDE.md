# gg.nvim

Standalone, UI-free GitLab API layer for Neovim. It has no user
commands. The only exception is `:checkhealth`.

for any reference, the old plugin is at C:/Users/marius.schaffner/Documents/work/github/atlas.nvim/

## Fixed decisions

Do not change these without asking me.

- **Neovim >= 0.10.** Use only built-in APIs (`vim.system`, `vim.json`, `vim.uv`).
- **HTTP via `curl` through `vim.system`.** No plenary, no runtime dependencies.
- **GraphQL-first for reads.** REST for binary downloads, job logs, and anything
  GraphQL doesn't cover. The choice of backend is internal to each resource module,
  and callers never see it.
- **Async.** Every request returns a Task that can be cancelled, used with a
  callback, or awaited inside a coroutine. No blocking calls (`vim.wait`,
  `:wait()` on `vim.system`) outside of tests.
- **Tests.** mini.test, run headless. The command is `make test`.
- **Types.** LuaLS annotations on every public function and every model.

## Architecture

```
lua/gg/
  init.lua            public facade; the ONLY stable surface for consumers
  config.lua          defaults, schema, validation
  health.lua          :checkhealth gitlab_api
  core/               task (async), errors, log
  transport/          http, auth, pagination, ratelimit
    backends/         curl (real), fake (replays fixtures)
  graphql/            client + queries/*.graphql (queries as files, not Lua strings)
  rest/               client
  context/            parse remote URLs -> host + project path (pure, no git calls)
  models/             domain objects + mappers from raw JSON (pure)
  resources/          one module per resource (issues, merge_requests, milestones,
                      pipelines, jobs, artifacts, registry, labels, users, notes ...)
tests/
  fixtures/rest/      recorded, sanitized responses
  fixtures/graphql/
  unit/
docs/refactor/        INVENTORY.md (input), PLAN.md (working checklist)
```

### Dependency direction

```
init -> resources -> (graphql | rest) -> transport -> core
resources -> models          models and context are pure and depend on nothing
```

Nothing may require a module above it. `init.lua` only re-exports.
This plugin never shells out to `git`. Consumers pass in remote URLs.

## Conventions

- **Errors.** Never throw across the public API. Return a normalized error with
  `kind`, `status`, `message` and `details`. Kinds: `auth`, `forbidden`,
  `not_found`, `validation`, `rate_limited`, `timeout`, `network`, `graphql`,
  `unknown`.
- **GraphQL errors.** An HTTP 200 with an `errors` array is an error.
  Partial data plus errors must be handled explicitly, not silently dropped.
- **Pagination.** Resources expose a single-page call (returns items + cursor)
  and an iterator / collect-all with a required upper limit. Nothing may silently
  return only the first page.
- **Projects.** Accept a full path or a numeric ID. Always URL-encode paths.
- **Multi-host.** Every call resolves its host explicitly. No global "current host".
- **Large payloads.** Artifacts and logs stream to a file path or a callback.
  Never buffer them whole in Lua.
- **Secrets.** Tokens never appear in logs, error messages, fixtures or test
  output. Redact them.
- **State.** No global mutable state beyond configured defaults.
- **Models.** Consumers only ever see mapped models, never raw API JSON.

## Testing

- No real network calls in tests. The fake backend replays fixtures.
- Fixtures come from real API responses and are sanitized: tokens, emails,
  internal hostnames and personal names are replaced.
- Every resource has tests for success, pagination and error mapping.
- Run `make test` after every change. A task isn't done until the suite is green.

## Working rules

- The plan lives in `docs/refactor/PLAN.md` as a checklist. Work through it in
  order, tick items off, and commit once per item.
- The old plugin is a reference for **required behavior**, not for implementation.
  Do not copy its code.
- Check GitLab API behavior against the official docs (docs.gitlab.com),
  not against memory.
- Ask before: adding a dependency, changing a public signature, deleting anything
  not on an approved list, or deviating from this file.
