# gg.nvim

Standalone GitLab API layer for Neovim, plus an optional UI layer (`gg.ui`)
built on top of it. The API layer has no user commands and no UI; the only
commands are `:checkhealth gg` and the UI's `:Gitlab` (in `plugin/gg.lua`).

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
  ui/                 optional UI layer (see "UI layer" below)
    lib/              pure helpers: display-width text, line builder, dates, hints
    components/       reusable UI pieces: layout, floats, prompt, list buffer, tabs
    issues/           issues picker: filter, model, paginate, columns, render (pure) + view
    merge_requests/   merge requests picker view (same split)
    pipelines/        pipelines picker view (same split; also mounted in the MR detail view)
    create/           creation popups: popup (windows), defs/* (one definition per
                      view: issue, merge_request, milestone, pipeline), ref_picker,
                      refs, variables_view; pure: layout, model, placeholders,
                      variables, mr
    detail/           detail views: host (windows), header/sidebar (pure), activity/,
                      issue/, milestone/, merge_request/, pipeline/ (pure parts + view);
                      editing: edit.lua (runner), editing.lua + fields.lua (glue),
                      edits.lua (pure payloads); components text_edit, field_edit,
                      composer, confirm
plugin/gg.lua         registers :Gitlab (lazy; loads gg.ui only when run)
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
The API layer never shells out to `git`. Consumers pass in remote URLs.

### UI layer

```
gg.ui.* -> gg (the facade) only        nothing outside gg.ui requires gg.ui
```

- `gg.ui` is a consumer of the API: it requires only `gg` and `gg.ui.*`, never
  resources/graphql/transport directly. Consumers only see mapped models.
- Its options live in `require("gg.ui").setup()`, separate from `gg.setup()`.
- `lua/gg/ui/project.lua` is the one module allowed to run `git` (async via
  `vim.system`): `git remote get-url origin` to find the project, and for the
  creation popups `git branch --show-current` and, after the user confirms,
  `git push -u origin <branch>`.
- `ui/lib`, the pure parts of `ui/issues` (filter, model, paginate, columns,
  render), `ui/components/tabs.lua` and everything under `ui/detail` except
  `view.lua`, `host.lua`, `init.lua`, `edit.lua`,
  `editing.lua` and `fields.lua`, and `layout`, `model`, `placeholders`,
  `variables` and `mr` under `ui/create` do not touch `vim.api`;
  they are tested headless without windows.
- Every change to GitLab from a detail view goes through `ui/detail/edit.lua`
  (`edit.run`: notice, request, apply or roll back, redraw) and then
  `stack:changed(kind)`, so the screens below refresh when shown again.
- Creation popups (`gg.ui.create.*`) are one generic popup
  (`ui/create/popup.lua`) driven by a definition per view (`ui/create/defs`).
  It has its own submit state in the body's border instead of `edit.run`,
  and calls `stack:changed(kind)` like the detail views.
- A float border can carry a left and a right label (`title_right`,
  `footer_right` in `ui/components/float.lua`); `float_group` rebuilds them
  on resize and focus changes.
- Screens stack: the picker is the bottom of a `ui/components/stack`; detail
  views are pushed on it (`gg.ui.detail.*`) and reach other screens only
  through it (`q` back, `Q` close all). A covered screen is hidden and its
  timers are suspended.
- Colours come only from highlight groups defined with `default = true`.
- Key hints are always written `[<key>] <description>`.

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

- The old plugin is a reference for **required behavior**, not for implementation.
  Do not copy its code.
- Check GitLab API behavior against the official docs (docs.gitlab.com),
  not against memory.
- Ask before: adding a dependency, changing a public signature, deleting anything
  not on an approved list, or deviating from this file.
