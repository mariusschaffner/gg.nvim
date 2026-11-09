# Merge requests table — UI spec

Sources: 

UI Design image: ./mergerequest_table_design.png
UI Design spec: ./mergerequest_table_design_spec.md
UI Design helpers: ./mergerequest_table_design_helpers/

This spec translates the mockup into Neovim terms. The mockup was drawn in HTML, so pixel values have been converted to terminal cells (JetBrains Mono 13px ≈ 7.8px per cell). Where the spec and the image / helpers disagree, the image / helpers win.

It builds on the issues picker (`docs/issue_table_design.md`). **Reuse everything shared** — the bordered float component, the filter prompt, the tab line, cursor rules, highlight setup and the loading/error/empty states. Only what differs is specified here.

The API layer already exists. This UI only reads from it. Don't change the API layer without asking first.

---

## 1. What it is

A full-editor floating view listing the project's merge requests (MRs), one line per MR, no grouping.

```
╭ [/] Filter ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│ ❯ █ Filter                                                                                                                             │
╰────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯
╭ Table ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│ [Open 6]  Merged 2  Closed 1  All 9                                                                                                    │
│                                                                                                                                        │
│     !    Title                           Source                   Target   Reviewers       Assignee     Pipeline  Diff                 │
│ ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────── │
│ ▌ !88  Rotate Terraform state back…      feat/rotate-tf-creds     main     @sfrei          @marro       ✓ ✓ ✓ ▸    +120   −34 ██████░░ │
│   !87  [Draft] WinRM over HTTPS lis…     feat/winrm-https         main     —               @marro       ✓ ◐ ○ ○    +310   −12 ███████░ │
│   !86  OCI load balancer module for…     feat/oci-edge-lb         main     @lhuber @sfrei  @marro       ✓ ✗ ○ ○    +482    −0 ████████ │
│   !85  DNS-01 wildcard renewal via …     feat/dns01-wildcard      main     @marro          @sfrei       ✓ ✓ ✓ ▸     +96    −8 ███████░ │
│   !84  Fix flaky weekend backup sch…     fix/backup-weekend       main     @marro          @lhuber      ✓ ✓ ✓ ✓     +14    −6 ██████░░ │
│   !83  Bump Ansible collections          chore/bump-collections   main     —               unassigned   ✓ ✓ ✓ ▸     +40   −40 ████░░░░ │
╰ [i] Merge Request ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯
```

(The sketch is approximate — §3 has the exact column rules. In the bar, `█` stands for both colours: additions are green, deletions red.)

---

## 2. Windows & layout

Same two-float layout as the issues picker:

| Window | Title | Footer | Notes |
|---|---|---|---|
| Filter | ` [/] Filter ` | — | Placeholder text `Filter` when empty. **No match counter.** |
| Table | ` Table ` | ` [i] Merge Request ` (left) | |

Table buffer lines:

1. **Tabs line:** `Open N   Merged N   Closed N   All N` (GitLab MR states: `opened`, `merged`, `closed`). Same styling as the issue tabs. Default tab: **Open**.
2. empty line
3. **Column header** (`GitlabColumnHeader`): `!`, `Title`, `Source`, `Target`, `Reviewers`, `Assignee`, `Pipeline`, `Diff`
4. **Separator** `─` (`GitlabSeparator`)
5. **Rows:** one line per MR. Rows are separated by a thin separator line drawn as `virt_lines` (not selectable).

---

## 3. Columns (cells)

`<cursor mark><!iid><title><source><target><reviewers><assignee><pipeline><diff>`

| Column | Width | Content | Highlight |
|---|---|---|---|
| Cursor mark | 2 | `▌ ` on the cursor line, else 2 spaces | `GitlabCursorMark` |
| `!` | 6 | `!88` | `GitlabIid` |
| Title | flexible (min 20) | `[Draft] ` prefix if draft, then title, truncated with `…` | prefix `GitlabDraft`, title `Normal` |
| Source | 24 | source branch, truncated with `…` | `GitlabBranchSource` |
| Target | 8 | target branch, truncated with `…` | `GitlabBranchTarget` |
| Reviewers | 17 | `@user` per reviewer, space separated, truncated with `…`; `—` if none | per-user colour (§4); `—` in `GitlabEmpty` |
| Assignee | 13 | first assignee as `@user` (`+N` if more); `unassigned` if none | per-user colour (§4); `unassigned` in `GitlabUnassigned` |
| Pipeline | 9 | one icon per stage of the head pipeline, in order, separated by one space. More than 4 stages: show the first 3 and then `…`. No pipeline: `—` | per-status (§5) |
| Diff | 20 | additions right-aligned in 5 cells, 1 space, deletions right-aligned in 5 cells, 1 space, then an 8-cell bar | §6 |

Rules:

- **2 cells gap** between columns.
- **Narrow windows:** when the title would drop below 20 cells, hide columns in this order: Target → Reviewers → Diff bar (keep the numbers) → Source.
- Truncate by **display width**, never by bytes. The glyphs `✓ ✗ ◐ ○ ▸ ⊘ – █ ░ ▌ …` are multi-byte.
- Target is usually `main`. It stays its own column because it isn't always `main`.

---

## 4. User colours

Usernames are coloured so the same person is recognisable across Reviewers and Assignee (and later across other views).

- 8 highlight groups `GitlabUser1` … `GitlabUser8`, linked by default to distinct standard groups: `Function`, `Special`, `Constant`, `Statement`, `String`, `Type`, `Identifier`, `PreProc`.
- A username always maps to the same group: a simple stable hash of the username, modulo 8.
- `setup({ user_colors = { ["marro"] = "GitlabUser1" } })` can pin a user to a group.
- The current user (from the API/token) is additionally **bold**.

The mockup used: @marro blue, @sfrei teal, @lhuber orange, @renovate purple.

---

## 5. Pipeline stage icons

| GitLab status | Icon | Highlight (default link) |
|---|---|---|
| `success` | `✓` | `GitlabPipelineSuccess` → `DiagnosticOk` |
| `failed` | `✗` | `GitlabPipelineFailed` → `DiagnosticError` |
| `running` | `◐` | `GitlabPipelineRunning` → `DiagnosticWarn` |
| `pending`, `created`, `waiting_for_resource`, `preparing`, `scheduled` | `○` | `GitlabPipelinePending` → `Comment` |
| `manual` | `▸` | `GitlabPipelineManual` → `Comment` |
| `canceled` | `⊘` | `GitlabPipelineCanceled` → `Comment` |
| `skipped` | `–` | `GitlabPipelineSkipped` → `NonText` |

A stage's status is the stage status from the API. If the API only offers job statuses, derive it: any failed → failed, else any running → running, else any manual → manual, else all success → success, otherwise pending.

---

## 6. Diff column

- `+<additions>` in `GitlabDiffAdd` (default link `DiffAdd` fg, or `Added` in Neovim ≥ 0.10).
- `−<deletions>` (U+2212 minus) in `GitlabDiffDelete` (`Removed`).
- Bar: 8 cells of `█`. The green share is `round(additions / (additions + deletions) * 8)`, at least 1 cell when additions > 0, and likewise for deletions. Green part `GitlabDiffAdd`, red part `GitlabDiffDelete`.
- Both 0, or stats not loaded yet: `·` placeholders in `Comment` (don't block the row).
- Numbers above 9999 are shown as `9.9k`.

---

## 7. Data

Per MR the view needs:

| Field | Typical source |
|---|---|
| iid, title, draft, state, source/target branch, reviewers, assignees, updated_at | MR list endpoint |
| head pipeline + per-stage status | head pipeline → its stages/jobs |
| additions / deletions | MR changes/diffs, or GraphQL `diffStatsSummary { additions deletions }` |

The pipeline stages and diff stats may need **extra requests per MR**. Handle them like this:

- Render the row as soon as the list arrives; fill the Pipeline and Diff cells **asynchronously** when they come in, and re-render only those lines.
- Limit concurrency (e.g. 4 requests at a time) and cache results per MR by `updated_at` / pipeline id.
- If GitLab GraphQL is available in the API layer, prefer one query that returns list + `headPipeline { stages { nodes { name status } } }` + `diffStatsSummary`.

The plan must state which of these the API layer already provides and which are missing.

Default sort: `updated_at` desc.

---

## 8. Interaction

Shared behaviour (R` refresh, `q`/`<Esc>` close) works exactly as in the issues picker.

MR-specific keys:

| Key | Action |
|---|---|
| `i` / `<CR>` | inspect the MR under the cursor (existing detail view, otherwise `on_inspect_mr(mr)` callback, default `vim.notify` stub) |

All keys are buffer-local and configurable.

---

## 9. Highlight groups (new in this view)

All `default = true`. Hex values are what the mockup used (Tokyo Night) — reference only.

| Group | Default link | Mockup colour |
|---|---|---|
| `GitlabDraft` | `Comment` | #8a90b8, boxed |
| `GitlabBranchSource` | `Statement` | #bb9af7 |
| `GitlabBranchTarget` | `Comment` | #a9b1d6 |
| `GitlabUser1`…`GitlabUser8` | see §4 | blue / teal / orange / purple … |
| `GitlabPipeline*` | see §5 | ✓ #9ece6a ✗ #f7768e ◐ #e0af68 |
| `GitlabDiffAdd` | `Added` (fallback `DiffAdd`) | #9ece6a |
| `GitlabDiffDelete` | `Removed` (fallback `DiffDelete`) | #f7768e |

Shared groups (`GitlabIid`, `GitlabCursorMark`, `GitlabSeparator`, `GitlabEmpty`, `GitlabUnassigned`, `GitlabTab*`, `GitlabColumnHeader`, border/title groups) come from the issues picker.

---

## 11. Acceptance checklist

- [ ] Opens by <tab> from the main issue table. tab should cycle through the issue and merge request views
- [ ] Footer `[i] Merge Request`, filter title `[/] Filter`, table title `Table`.
- [ ] Every column lines up on every row, including drafts and rows with missing data.
- [ ] Reviewers/assignee coloured per user, consistently; the current user bold.
- [ ] Pipeline shows only stage icons, correct per status; `—` without a pipeline.
- [ ] The diff numbers right-align in fixed slots, so every bar starts in the same column.
- [ ] Rows appear immediately; pipeline and diff fill in asynchronously without moving the cursor.
- [ ] Open / Merged / Closed / All tabs with correct counts.
- [ ] Headless tests for model and render: truncation with multi-byte glyphs, narrow-width hiding order, diff bar maths, stage status derivation, user colour hashing being stable.
