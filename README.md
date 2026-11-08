# gg.nvim

A standalone, UI-free GitLab API layer for Neovim.

gg talks to GitLab's GraphQL and REST APIs, and returns plain Lua tables with GitLab's own field names. It has no
UI and no user commands; `:checkhealth gg` is the only command. Plugins build their interface on top of it.

- **Async.** Every call returns a Task. Use it with a callback, await it in a coroutine, or cancel it.
- **Never throws.** Failures are normalized errors with a `kind`: `auth`, `forbidden`, `not_found`, `validation`,
  `rate_limited`, `timeout`, `network`, `graphql` or `unknown`.
- **Multi-host.** Every call names its host, and tokens are configured per host.
- **Explicit pagination.** Each list has a single-page call (with a cursor) and a collect-all call with a required
  limit. Nothing is cut off silently.
- **Safe with tokens.** The token reaches curl through stdin and is never sent to other hosts on redirects. It is
  redacted from errors and logs.
- **No dependencies.** It needs Neovim 0.10+ and `curl`.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "mariusschaffner/gg.nvim",
  config = function()
    require("gg").setup({
      hosts = {
        ["gitlab.example.com"] = { token = function() return os.getenv("GITLAB_WORK_TOKEN") end },
      },
    })
  end,
}
```

Then run `:checkhealth gg`.

## Setup

`hosts` is the only thing you must set. There is no default instance, and gg sends requests only to the hosts you
list (gitlab.com included: list it if you use it).

```lua
require("gg").setup({
  hosts = {
    ["gitlab.example.com"] = {
      token = "...", -- or a function returning the token; or set GITLAB_TOKEN
      -- optional:
      -- base_url = "https://gitlab.example.com/gitlab", -- default https://<host>; may include a relative root
      -- aliases = { "ssh.gitlab.example.com" },         -- other names, e.g. an SSH host
    },
  },
})
```

Everything else is optional and has a default:

```lua
require("gg").setup({
  hosts = { ... },
  timeout = { connect = 10, total = 60, stall = 30 },  -- seconds
  retry = { max_attempts = 3, base_delay_ms = 500, max_delay_ms = 30000, max_retry_after_s = 60 },
  log = { level = "warn" },                            -- written to stdpath("log")/gg.log
})
```

Tokens are looked up per request: first the host's `token`, then `GITLAB_TOKEN`, and otherwise none (public data
only). A call to a host that isn't in `hosts` fails with a `validation` error. `setup` returns `true`, or
`false, err` when an option is invalid.

## Usage

```lua
local gg = require("gg")

-- which project does this remote point to? (gg never runs git; pass the URL in)
local repo = gg.context.parse("git@gitlab.example.com:group/sub/repo.git", { hosts = gg.config.hosts() })

-- with a callback
gg.issues.list({ host = repo.host, project = repo.project, state = "opened" }, { per_page = 20 })
  :on_done(function(page, err)
    if err then
      return vim.notify(tostring(err), vim.log.levels.ERROR)
    end
    for _, issue in ipairs(page.items) do
      print(issue.iid, issue.title, issue.state)
    end
  end)

-- in a coroutine
local t = gg.task.run(function()
  local mr, err = gg.merge_requests.get({ host = repo.host, project = repo.project, iid = 42 }):await()
  if err then
    return nil, err
  end
  local checks = gg.mr_checks.get({ host = repo.host, project = repo.project, iid = 42 }):await()
  return { mr = mr, mergeable = checks and checks.mergeable }
end)
t:on_done(function(result, err) end)
t:cancel() -- cancels the request in flight
```

## Pagination

```lua
-- one page; pass page.next_cursor back as opts.cursor
local page = gg.labels.list(args, { per_page = 100 })

-- collect pages up to a limit; truncated = true when more existed
gg.labels.list_all(args, { limit = 500, on_page = function(items) end })
  :on_done(function(res, err) --[[ res.items, res.truncated ]] end)
```

## Resources

| Module | Functions |
|---|---|
| `gg.issues` | `list`, `list_all`, `get`, `by_iids`, `create`, `update` |
| `gg.work_items` | `dates`, `update_dates` |
| `gg.merge_requests` | `list`, `list_all`, `get`, `by_iids`, `related_to_issue[_all]`, `create`, `update`, `merge` |
| `gg.mr_changes` | `commits[_all]`, `diffs[_all]`, `diffstat`, `versions[_all]`, `latest_version` |
| `gg.mr_checks` | `get` |
| `gg.notes` | `discussions[_all]`, `list`, `list_all`, `add`, `reply`, `edit`, `delete`, `set_resolved` |
| `gg.reviews` | `reviewers`, `drafts[_all]`, `create_draft`, `edit_draft`, `delete_draft`, `discard_drafts`, `publish`, `approve` |
| `gg.milestones` | `list`, `list_all`, `get`, `issues[_all]`, `merge_requests[_all]`, `create`, `update` |
| `gg.labels` | `list`, `list_all` |
| `gg.users` | `current`, `project_members[_all]` |
| `gg.branches` | `list`, `list_all`, `related_to_issue[_all]`, `create` |
| `gg.projects` | `search`, `search_all`, `get` |
| `gg.todos` | `list`, `list_all`, `mark_done` |
| `gg.pipelines` | `list`, `list_all`, `get`, `graph`, `retry`, `cancel` |
| `gg.jobs` | `list`, `list_all`, `get`, `trace` (streamed), `retry`, `cancel`, `play` |
| `gg.artifacts` | `download`, `download_file`, `download_ref`, `download_ref_file` (all streamed) |
| `gg.registry` | `repositories[_all]`, `tags[_all]`, `tag` |

Every function takes `args` with an explicit `host`. `project` is a full path or a numeric ID. `:help gg` documents
each function's arguments and results; the LuaLS annotations in `lua/gg/models/` list every model field.

## Errors

```lua
gg.issues.get({ host = h, project = p, iid = 999 }):on_done(function(issue, err)
  if err and err.kind == "not_found" then ... end
  -- err = { kind, status, message, details }; tostring(err) is readable
end)
```

A GraphQL response with an `errors` array is a `graphql` error. Any data that came with it is in
`err.details.partial`, and is never returned as a success.

## Testing your plugin

`gg.testing.fake_backend` replays recorded responses, so your tests never touch the network:

```lua
local fake = require("gg").testing.fake_backend.new({ root = "tests/fixtures" })
fake:load("graphql/issues/get.json")
require("gg").setup({ hosts = { ["gitlab.example.com"] = { token = "test" } }, transport = { backend = fake } })
-- call gg, then inspect fake:requests()
```

See `:help gg-testing` for the fixture format.

## Development

```sh
make test                                        # whole suite, headless (mini.test)
make test-file FILE=tests/unit/resources/test_issues.lua
```

Tests never call the network. Fixtures under `tests/fixtures/` are sanitized real responses; see
`tests/fixtures/README.md` and `scripts/sanitize_fixture.lua`.
