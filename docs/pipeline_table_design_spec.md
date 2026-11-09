# Pipelines table — UI spec

Sources: 

UI Design image: ./pipeline_table_design.png
UI Design spec: ./pipeline_table_design_spec.md
UI Design helpers: ./pipeline_table_design_helpers/

This spec translates the mockup into Neovim terms. The mockup was drawn in HTML, so pixel values have been converted to terminal cells (JetBrains Mono 13px ≈ 7.8px per cell). Where the spec and the image / helpers disagree, the image / helpers win.

It is the third view on the same foundation as `docs/issues_table_desgin_spec.md` and `docs/mergerequest_table_design_spec.md`. **Reuse everything shared:** bordered float, filter prompt, tab line, column header, cursor rules, shared table module, highlight setup, loading/error/empty states and the **pipeline stage icons** (merge requests spec §5). Only what differs is specified here.

The API layer already exists. This UI only reads from it. Don't change the API layer without asking first.

---

## 1. What it is

A full-editor floating view listing the project's pipelines, newest first, one line per pipeline, no grouping.

```
╭ [/] Filter ──────────────────────────────────────────────────────────────────────────────────────────────╮
│ ❯ █ Filter                                                                                                                           │
╰────────────────────────────────────────────────────────────────────────────────────────────────────────╯
╭ Table ───────────────────────────────────────────────────────────────────────────────────────────────────╮
│ [All 8]  Running 1  Failed 2  Passed 4                                                                                                │
│                                                                                                                                       │
│     Status       #      Ref                          MR     Commit                         Source   Stages    Started │
│ ────────────────────────────────────────────────────────────────────────────────────────────────────── │
│   ◐ running    #4821  feat/winrm-https             !87    a1f3c9e Add HTTPS listener task  push     ✓ ◐ ○ ○    2m ago │
│ ▌ ✗ failed     #4819  feat/oci-edge-lb             !86    7c2e0b1 Add backend set health…  push     ✓ ✗ – –    1h ago │
│   ▸ waiting    #4817  feat/rotate-tf-creds         !88    3d9aa47 Move state key to CI v…  push     ✓ ✓ ✓ ▸    2h ago │
│   ✓ passed     #4815  feat/dns01-wildcard          !85    e58b21f Handle CAA records       MR       ✓ ✓ ✓ ▸    3h ago │
│   ✓ passed     #4812  main                                9f0c3d2 Merge !82 Pin PowerShe…  push     ✓ ✓ ✓ ✓    8h ago │
│   ⊘ canceled   #4810  fix/backup-weekend           !84    1b77e40 Shift schedule to 02:30  push     ✓ ⊘ – –    1d ago │
│   ✓ passed     #4808  main                                9f0c3d2 nightly drift check      schedule ✓ ✓ ✓ –    1d ago │
│   ✗ failed     #4806  main                                c4a81de nightly drift check      schedule ✓ ✓ ✗ –    2d ago │
╰ [i] Pipeline ────────────────────────────────────────────────────────────────────────────────────────────╯
```

(The sketch is approximate — §3 has the exact column rules.)

---

## 2. Windows & layout

Same two-float layout as the other views:

| Window | Title | Footer | Notes |
|---|---|---|---|
| Filter | ` [/] Filter ` | — | Placeholder `Filter` when empty. No match counter. |
| Table | ` Table ` | ` [i] Pipeline ` (left) | |

Table buffer lines:

1. **Tabs line:** `All N   Running N   Failed N   Passed N`. Default tab: **All**.
   - Running = `running`, `pending`, `created`, `preparing`, `waiting_for_resource`
   - Failed = `failed`
   - Passed = `success`
   - All = everything, including `manual`, `canceled`, `skipped`, `scheduled`
2. empty line
3. **Column header:** `Status`, `#`, `Ref`, `MR`, `Commit`, `Source`, `Stages`, `Started` (right-aligned)
4. **Separator** `─`
5. **Rows:** one line per pipeline, with a thin non-selectable separator (`virt_lines`) between rows.

---

## 3. Columns (cells)

| Column | Width | Content | Highlight |
|---|---|---|---|
| Cursor mark | 2 | `▌ ` on the cursor line | `GitlabCursorMark` |
| Status | 13 | icon + word (§4) | per status (§4) |
| `#` | 7 | `#4821` (pipeline **id**, as GitLab shows it) | `GitlabIid` |
| Ref | 27 | branch or tag name, truncated with `…` | default branch `GitlabRefDefault`, other branches `GitlabBranchSource`, tags `GitlabRefTag` |
| MR | 6 | `!87` if the pipeline belongs to an MR (MR pipeline, or branch pipeline of an open MR); empty otherwise | `GitlabIid` |
| Commit | flexible (min 20) | short SHA (8 chars), space, commit title; truncated with `…` | SHA `GitlabSha`, title `Normal` |
| Source | 10 | short source label (§5) | `GitlabPipelineSource`; `schedule` in `GitlabPipelineSourceSchedule` |
| Stages | 9 | stage icons, same rules as the MR view (one icon per stage, space separated; more than 4 stages → first 3 + `…`) | per stage status |
| Started | 8, right-aligned | relative time: `now`, `12s ago`, `2m ago`, `3h ago`, `2d ago`, older than 7 days → `%b %d` | `Comment` |

Rules:

- **2 cells gap** between columns.
- **Narrow windows:** hide in this order: MR → Source → Ref (truncate first, then hide) → Started.
- Truncate by display width; glyphs are multi-byte.
- "Started" uses `started_at`, falling back to `created_at` for pipelines that haven't started.

---

## 4. Status column

Icon and word for the pipeline's overall status. The icons are the same as the stage icons, and so are their highlight groups.

| GitLab status | Shown as |
|---|---|
| `success` | `✓ passed` |
| `failed` | `✗ failed` |
| `running` | `◐ running` |
| `pending`, `created`, `preparing`, `waiting_for_resource` | `○ pending` |
| `manual` | `▸ waiting` (blocked on a manual job) |
| `scheduled` | `○ scheduled` |
| `canceled` | `⊘ canceled` |
| `skipped` | `– skipped` |

A failed pipeline with `allow_failure` jobs only is shown by GitLab as `success` with warnings. Show `✓ passed` and append `!` in `DiagnosticWarn` if the API exposes that warnings flag.

---

## 5. Source labels

| GitLab `source` | Label |
|---|---|
| `push` | `push` |
| `merge_request_event` | `MR` |
| `schedule` | `schedule` |
| `web` | `manual` |
| `api` | `api` |
| `trigger`, `pipeline`, `parent_pipeline` | `trigger` / `child` |
| other | the raw value, truncated |

---

## 6. Data

Per pipeline the view needs:

| Field | Typical source |
|---|---|
| id, status, ref, tag flag, sha, source, created_at / started_at, user | pipeline list endpoint |
| commit title | commit lookup by sha (list endpoint usually doesn't have it) |
| linked MR | MR pipelines carry it; for branch pipelines, match the ref against open MRs |
| stages with status | pipeline jobs, grouped by stage |

As in the MR view, rows render immediately from the list. **Commit title, MR link and stages fill in asynchronously,** with limited concurrency and a cache:
- the commit title cached by sha
- the stages cached by pipeline id; only refetch while the pipeline is still active

If GraphQL is available, one `project.pipelines` query with `commit { title }`, `mergeRequest { iid }` and `stages { nodes { name status } }` replaces most of the extra requests. The plan must say what the API layer already offers.

Default sort: id desc (newest first). Page size: 50, with **`]p` / `[p`** to page or load more (the buffer appends rows).

### Live updates

While the view is open and at least one visible pipeline is active (running, pending, preparing, waiting_for_resource), refresh those pipelines every **10 s** (configurable, `0` = off). Update only the affected lines: no full re-render, no cursor jump. Also refresh the relative "Started" times every 30 s.

---

## 7. Interaction

Shared behaviour (filter focus, tabs with `<Tab>`/`<S-Tab>`, cursor rules, selection kept across re-renders, `R` refresh, `q`/`<Esc>` close) as in the other views.

| Key | Action |
|---|---|
| `i` | inspect the pipeline under the cursor (existing detail view, otherwise `on_inspect_pipeline(pipeline)` callback, default `vim.notify` stub) |
| `P` | next / previous page |

### Filter syntax

Space-separated tokens, all must match (AND), case-insensitive:

- `status:<status>`: GitLab status or the shown word (`status:failed`, `status:waiting`)
- `source:<label>`: e.g. `source:schedule`, `source:MR`
- `ref:<text>`: ref contains text (`ref:main`)
- `@user`: triggered by user (filter only, there's no column for it)
- `#4821` / `4821`: pipeline id
- `!87`: linked MR
- anything else → substring of ref, commit title or SHA

---

## 8. Highlight groups (new in this view)

All `default = true`; hex = mockup reference only.

| Group | Default link | Mockup colour |
|---|---|---|
| `GitlabRefDefault` | `Special` | #7dcfff |
| `GitlabRefTag` | `Constant` | — |
| `GitlabSha` | `DiagnosticWarn` | #e0af68 |
| `GitlabPipelineSource` | `Comment` | #8a90b8 |
| `GitlabPipelineSourceSchedule` | `DiagnosticWarn` | #e0af68 |

Reused: `GitlabPipeline*` (stage/status icons), `GitlabBranchSource`, `GitlabIid`, `GitlabCursorMark`, `GitlabSeparator`, tabs, header and border groups.

---

## 10. Acceptance checklist

- [ ] falls into the tab cycle of issue and merge request tables
- [ ] All / Running / Failed / Passed tabs with correct counts and membership (§2).
- [ ] Status shows icon + word; stages show icons only, identical to the MR view's icons.
- [ ] Default branch, other branches and tags are visually different in Ref.
- [ ] The MR column is filled for MR pipelines and branches with an open MR.
- [ ] Rows appear immediately; the commit title, MR and stages fill in without moving the cursor.
- [ ] Active pipelines update live; the timer stops when the view closes or nothing is active.
- [ ] Paging with `P` works and keeps the selection.
- [ ] Filter tokens from §7 work.
- [ ] Headless tests: status/source mapping, tab membership, relative time formatting, narrow-width hiding order, truncation with multi-byte glyphs.
