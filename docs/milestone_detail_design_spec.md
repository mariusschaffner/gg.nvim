# Milestone detail — UI spec

Shared foundation: `docs/detail_views_design_spec.md`. Opened by `I` in the issues table and by `gm` in the issue detail view.

## Header

- **Pill:**

  | Condition | Pill |
  |---|---|
  | the milestone is closed | Closed |
  | the start date is in the future | Upcoming |
  | the due date is in the past | Overdue |
  | otherwise | Active |

- **Title line:** the title, then `%id`.
- **Border:** `group / project › milestones › %id` on the left; `project milestone · updated <age> ago` (or `group milestone …`) on the right.
- **Date strip** (`detail/milestone/timeline.lua`), three lines:

  ```
   │02.11.              │09.11.       15.11.│
   ━━━━━━━━━━━━━━━━━━━━━━━━┃─────────────────
                         today
  ```

  - **Range:** from the start date, or the creation date when only a due date is set, to the due date.
  - **Ticks:** at the start, every Monday in between, and the due date. A label that would collide is dropped; its tick stays.
  - **Bar by state:**

    | State | Bar |
    |---|---|
    | in progress | `━` up to the `┃` today marker, `─` after |
    | closed | dim `━` |
    | overdue | red `━` |
    | not started | `─` |

  - **Label line:** `today` under the marker, or `starts in N days` / `N days overdue` / `closed DD.MM.`.
  - **Without dates:** `no dates`.
- **Narrow windows:** `D/T closed · N doing · U unassigned · M MRs`.

## Tabs

1. **Description:** markdown, as in the issue view.
2. **Work items:** the issues table (`gg.ui.issues.render`) without the milestone column. Its own Open / Closed / All tabs switch with `L` / `H`. `i` / `<CR>` opens the issue. The tab label carries the count.
3. **Merge requests:** the merge requests table (`gg.ui.merge_requests.render`), with pipeline and diff cells from `gg.merge_requests.summaries`. `L` / `H` switch its states; `i` / `<CR>` opens the merge request.

## Sidebar

Issues are bucketed: closed is **done**; otherwise the `WF:Doing` / `WF:Done` / `WF:To do` label decides (case and spaces don't matter); with no such label, **to do**.

- **PROGRESS:** one dot per issue (at most the sidebar width), done `●` green, doing `●` purple, to do `○`; then `n/m closed`.
- **WORK ITEMS:**
  - `○ To do`, `◐ Doing` and `✓ Done`, each with its count on the right;
  - `unassigned N` (open issues without an assignee), only when N > 0.
- **IN PROGRESS:** after a divider, `#iid title` for every issue in the doing bucket.

## Data

- `gg.milestones.get` (by global id)
- `gg.milestones.issues_all` (by title, every state)
- `gg.milestones.merge_requests_all`
- `gg.merge_requests.summaries` (batches)
