# Test fixtures

The fake backend (`lua/gg/transport/backends/fake.lua`) replays these files.
Tests never make real network calls.

## Layout

```
tests/fixtures/
  rest/<resource>/<name>.json      REST responses
  graphql/<resource>/<name>.json   GraphQL responses
  transport/<name>.json            transport-level cases (pagination, errors)
```

## Format

A file holds one fixture, or an array of fixtures (for page sequences).

```json
{
  "meta": { "source": "docs.gitlab.com example (api/issues)", "sanitized": true },
  "request": { "method": "GET", "path": "/api/v4/projects/group%2Frepo/issues", "query": { "page": "1" } },
  "response": { "status": 200, "headers": { "x-next-page": "2" }, "body": [] }
}
```

- `request.path` is the raw, percent-encoded URL path.
- `request.query` must match the request's query exactly. `request.query_contains` matches a subset, and
  `request.body_contains` matches a subset of a JSON body. When neither is given, any query matches.
- GraphQL fixtures use `"request": { "operation": "IssueGet", "variables": { ... } }`. `variables` is a subset match.
- `response.body` is JSON (or a string). For binary data, use `response.body_base64`.
- `response.error = { "kind": "timeout" }` simulates a transport failure, and `response.delay` (ms) delays the answer.
- A fixture is used once. Add `"repeat": true` to serve it to every matching request.

## Sources

`meta.source` records where a response came from:

- `gitlab.com public, <date>`: a real response from a public gitlab.com project, fetched without a token.
- `docs.gitlab.com example (<page>)`: the example response from the official API docs. These cover endpoints
  that need authentication, and mutations.

Re-record with a token when one is available, and keep the same file names.

## Sanitization rules

Run every recorded response through the sanitizer:

```
nvim -l scripts/sanitize_fixture.lua raw.json tests/fixtures/rest/issues/list.json \
  --source "gitlab.com public, 2026-11-06" --method GET --path /api/v4/projects/1/issues
```

It applies these rules, and `tests/unit/test_fixtures.lua` enforces them on every file:

- No tokens. This covers `glpat-` and other `gl*-` prefixes, `PRIVATE-TOKEN`, and `private_token=`.
- E-mail addresses only at `example.com`.
- URL hosts only `gitlab.com`, `gitlab.example.com`, or `*.example.com|net|org`.
- User objects (anything with a `username`) have `username = user-N` and `name = Test User N`.
- Commit `author_name` and `committer_name` become `Test User N`.
