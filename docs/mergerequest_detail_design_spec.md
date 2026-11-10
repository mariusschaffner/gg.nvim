# Merge request detail — UI spec

Shared foundation: `docs/detail_views_design_spec.md`. The Activity tab has no footer hints. Opened by `i` / `<CR>` in the merge requests table, by `gp` in the issue view and by `i` / `<CR>` on a milestone's merge request.

## Header

- **Pill:** ` ● Open `, ` ● Draft `, ` ● Merged ` or ` ● Closed `.
- **Title line:** the title, then `!iid`.
- **Border:** `merge requests › !iid` on the left; `opened by … · updated … ago` on the right.
- **Readiness strip** (`detail/merge_request/readiness.lua`, `gg.ui.lib.strip`), three lines:

  ```
   (✓)━━━━━━━━━━━━━(✓)━━━━━━━━━━━━━━(◷)──────────────────────(⇣)
   Pipeline passed  No conflicts     Review · user-2      Merge into main
   [gp] pipeline                 waiting for approval            blocked
  ```

  - **Gates** (left out when they don't apply):

    | Gate | Shown when | States |
    |---|---|---|
    | Pipeline | a head pipeline exists, or GitLab waits for one | passed / running / failed / required |
    | Conflicts | always | — |
    | Review | reviewers or approvers exist | approved / review / changes requested, with names |
    | Threads | there are resolvable threads | resolved / `N unresolved threads` |
    | Draft | the MR is a draft | — |

  - **Blocking gate:** taken from `detailed_merge_status` when it maps to a gate; otherwise the first gate that has not passed. Its label takes its colour and its reason goes in the hint line.
  - **Merge node:**

    | Node | Meaning |
    |---|---|
    | `⇣` Ready to merge | nothing blocks the merge |
    | `⇣` Merge into `<target>` | blocked; the hint gives the reason (e.g. `needs rebase · blocked`) |
    | `●` Merged into `<target>` | merged; every gate turns green with neutral labels |
    | `✗` Closed | closed |

  - **Narrow windows:** one line, `✓ pipeline · ✓ no conflicts · ◷ review · ⇣ merge · blocked`.

## Tabs

1. **Description:** markdown. Footer: `[i] Edit`. Every line that closes issues (`Closes #12`, `fixes group/x#3 and #4`, `resolves issue #5`, …) is followed by one card per issue: `● #22  Title  WF:…`, with a dot green for open, purple for closed, dim while loading. Fenced code is skipped. `i` / `<CR>` on a card opens the issue (`i` is the edit key in this tab).
2. **Activity:** as in the issue view. Diff threads are shown, with `⎇ path:line`.
3. **Changes:** footer `[i] File` (opening a file comes with the review view; until then the key says so).
   - **Header:** `FILE  ADD  DEL  CHANGE`.
   - **One row per file:**
     - the path, with the directory dim and shortened by whole directories (`…/tasks/main.yml`);
     - `+N` green and `−N` red;
     - a 10-cell `■` bar scaled to the largest file, with at least one cell of each colour when the file has both kinds of change.
   - **Then:** a rule and `N files changed  +A  −D`.
4. **Commits:**
   - Grouped by day under dividers.
   - Each commit has a node (`○`, or `◇` for merges), a type chip (` feat `, ` fix `, …), the scope, `HH:MM`, the author and the short SHA.
   - The subject sits on the next row along a `│` guide. Merge commits read `source → target`.
   - An empty line separates the commits of a day; only the `│` graph line runs through it. No footer hints. The tab title carries no count.
5. **Pipelines:** the pipelines table (`gg.ui.pipelines.view` mounted with `mr_iid`).
   - One table of every pipeline of the merge request (no All / Running / Failed / Passed line); `P` loads more (no hint); `i` / `<CR>` opens the pipeline. Footer: `[i] Pipeline`.
   - Live refresh runs only while the tab is visible.

## Sidebar

- **BRANCHES:** `⎇ source`, then `↳ ⎇ target`.
- **ASSIGNEE.**
- **REVIEWERS:** each with `✓ approved` / `✗ changes` / `● reviewed` / `◷ pending`.
- **LABELS** and **MILESTONE**.
- A divider.
- **ON MERGE:** `●` / `○ Delete source branch`, then `● Close #n` for each closed issue.

## Keys

| Key | Action |
|---|---|
| `gp` | open the newest pipeline (from the Pipelines tab if it is loaded, else one request) |

## Data

Loaded in parallel:

- `gg.merge_requests.get`
- `gg.mr_checks.get`
- `gg.reviews.reviewers`
- `gg.mr_changes.stats` (exact per-file counts)
- `gg.mr_changes.commits_all`
- `gg.issues.by_iids` (the closed issues, per project)

The Activity and Pipelines tabs load when first shown.
