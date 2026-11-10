# Issue detail — UI spec

Shared foundation: `docs/detail_views_design_spec.md`. Opened by `i` in the issues table, by `i` / `<CR>` on a milestone's work item, and by `i` / `<CR>` on an issue card in a merge request's description.

## Header

- **Pill:** ` ● Open ` or ` ● Closed `.
- **Title line:** the title, then `#iid`.
- **Chip row:** label chips, then `◆ milestone`, then `│`, then the description's task progress (`● ○ 1/2 criteria`, only when it has tasks).
- **Border:** `issues › #iid` on the left; `opened by <author> · updated <age> ago` on the right.
- **Narrow windows:** the header adds `Open · @assignee · label · ◆ milestone · due <date> · <branch>`.

## Tabs

1. **Description.** Footer: `[i] Edit`. Markdown subset (`gg.ui.lib.markdown`):
   - headings in the accent colour, with `n of m done` right-aligned when tasks follow;
   - tasks `✓` / `○`, bullets `•` / `–`;
   - code fences shown as they are;
   - links reduced to their text, `#hashtags` highlighted.
2. **Activity** (shared with merge requests). Loaded the first time the tab is shown. No footer hints. The tab label carries the comment count.
   - **Events:** one line each — icon, actor, text, `HH:MM` on the right.
   - **Days:** a divider each, `TODAY · DD.MM.YYYY` / `YESTERDAY · …` / `DD.MM.YYYY`.
   - **Event runs:** more than 4 consecutive events show the first 2, `⋯ N more changes · [<CR>] expand`, and the last 2.
   - **Comments:**
     - Tinted blocks (90% of the width) with a `▎` bar.
     - The header shows the author, time, `you`, `✓ resolved thread` / `◷ unresolved thread`, and `⎇ path:line` for diff threads.
     - Replies hang below with `├─` / `└─` guides. Reactions are counted.
     - More than 8 lines are cut, with `… [za] expand`.
   - **Keys:**

     | Key | Action |
     |---|---|
     | `<CR>` | expand a run or folded replies |
     | `za` | expand a long comment, or fold the thread's replies |
     | `zA` | fold all threads |

## Sidebar

- **ASSIGNEE:** `(XX) Name`, or `unassigned`.
- **LABELS:** chips, wrapped.
- **MILESTONE:** `◆ title`.
- **START / DUE:** dates from the work item (start left, due right), else the issue's due date; `not scheduled` when there are none.
- A divider.
- **DEVELOPMENT:**
  - related branches, `⎇ name`;
  - related merge requests, `!iid title` (merged green, closed red).

## Keys

| Key | Action |
|---|---|
| `gm` | open the milestone (`No milestone` without one) |
| `gp` | open the related merge request; a `vim.ui.select` choice when there are several |

## Data

Loaded in parallel; each part renders as soon as it arrives:

- `gg.issues.get`
- `gg.work_items.dates`
- `gg.branches.related_to_issue_all` (limit 20)
- `gg.merge_requests.related_to_issue_all`
- `gg.notes.discussions_all` (Activity)
- `gg.users.current` (for the `you` badge)
