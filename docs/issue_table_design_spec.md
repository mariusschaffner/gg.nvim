# Issues picker (main view) — UI spec

Sources: 

UI Design image: ./issue_table_design.png
UI Design spec: ./issue_table_design_spec.md
UI Design helpers: ./issue_table_design_helpers/

This spec translates the mockup into Neovim terms. The mockup was drawn in HTML, so pixel values have been converted to terminal cells (JetBrains Mono 13px ≈ 7.8px per cell). Where the spec and the image / helpers disagree, the image / helpers win.

The plugin's API layer already exists. This UI only **reads** from it (and calls existing actions). Do not change the API layer without asking first.

---

## 1. What it is

A full-editor floating view that lists GitLab issues of one project, grouped by milestone:

- Issues **without a milestone are top level** — listed first, not under a "No milestone" group.
- Then one block per milestone. A left-hand **Milestone column** shows the milestone once, next to all of its issues (like a merged spreadsheet cell).
- A one-line **filter prompt** above the table filters live.
- **Open / Closed / All** tabs switch the issue state.

```
╭ Filter [/] ────────────────────────────────────────────────────────────────────────────────────────────╮
│ ❯ █ search title · ~label · %milestone · @user                                                         │
╰────────────────────────────────────────────────────────────────────────────────────────────────────────╯
╭ Table ─────────────────────────────────────────────────────────────────────────────────────────────────╮
│ [Open 9]  Closed 3  All 12                                                                             │
│                                                                                                        │
│   Milestone                 Issue                                   Labels            Assignee  State  │
│ ────────────────────────────────────────────────────────────────────────────────────────────────────── │
│   —                           #220  Flaky backup job on weekend…    ~bug ~backup      @lhuber   ● Open │
│ ────────────────────────────────────────────────────────────────────────────────────────────────────── │
│   —                           #198  Clean up unused container r…    ~chore            none      ● Open │
│ ────────────────────────────────────────────────────────────────────────────────────────────────────── │
│ ▎ %2026.11 Patch cycle      ▌ #214  Rotate Terraform state back…    ~security ~terr…  @marro    ● Open │
│ ▎ due Nov 20 · in 12d         #211  WinRM over HTTPS for newly …    ~ansible ~windows @marro    ● Open │
│ ▎ ▰▰▰▱▱▱▱▱▱▱ 2/6              #209  Monitoring sensor for pendi…    ~monitoring       @lhuber   ● Open │
│ ▎                             #205  Document patch-window rollb…    ~docs             none      ● Open │
│ ────────────────────────────────────────────────────────────────────────────────────────────────────── │
│ ▎ %2026.12 Cloud migration    #219  Migrate nginx gateway to OC…    ~oci ~network     @marro    ● Open │
│ ▎ due Dec 18 · in 40d         #218  Wildcard cert renewal via D…    ~oci ~dns         @sfrei    ● Open │
│ ▎ ▰▰▰▱▱▱▱▱▱▱ 1/4              #216  Terraform module for object…    ~terraform        @marro    ● Open │
╰ [I] Milestone • [i] Issue ─────────────────────────────────────────────────────────────────────────────╯
```

(Column widths in the sketch are approximate — use §4 for exact rules.)

---

## 2. Requirements & constraints

- Neovim **≥ 0.10**
- No hard UI dependency (no nui/telescope). Plain `vim.api`.
- Must never block the UI: all API calls async; show a loading state.
- Colours come only from highlight groups (§6) linked to standard groups, so any colourscheme works.
- Build all ui wherever possible as shared **reusable component**, since they will be shared across other ui viewes later.

---

## 3. Windows & layout

Two floating windows, `relative = "editor"`, `border = "rounded"`, `zindex = 50`:

| Window | Buffer | Size / position | Title | Footer |
|---|---|---|---|---|
| **Filter** | 1-line scratch buffer | width = editor width − 2, height 1, row 0, col 0 | ` [/] Filter` (left) | — |
| **Table** | scratch buffer (`nomodifiable` except while rendering) | same width, fills the rest of the editor height below the filter (minus 1 cell gap) | ` Table ` (left) | ` [I] Milestone • [i] Issue ` (left, `footer_pos = "left"`) |

- Use the full editor area (`vim.o.columns`, `vim.o.lines - vim.o.cmdheight`), minus the borders. Recompute and `nvim_win_set_config` on `VimResized`.
- **Focus styling:** the focused float's border uses `GitlabPickerBorderActive`, the other `GitlabPickerBorder` (via `winhighlight = "FloatBorder:…"`).
- Table window options: `cursorline`, `nowrap`, `nonumber`, `norelativenumber`, `signcolumn=no`, `foldcolumn=0`, `nospell`, `nolist`.
- Closing either float closes both (`WinClosed` / `BufLeave` handling), and restores the previous window.

### Filter window

- Prefix `❯ ` (virtual text, inline, `GitlabPickerPrompt`), then the user's input.
- When empty: placeholder `filter` as virtual text (`Comment`).
- Filters live on `TextChangedI` / `TextChanged` (debounce ~50 ms).

### Table window: line structure

1. **Tabs line** — `Open N   Closed N   All N`. Active tab: `GitlabTabActive` with one space of padding each side (` Open 9 `); others `GitlabTab`.
2. empty line
3. **Column header** — `GitlabColumnHeader`: `Milestone`, `Issue`, `Labels`, `Assignee`, `State` at the column starts from §4.
4. **Separator** — `─` across the full width, `GitlabSeparator`.
5. **Body** — the blocks from §5.

Lines 1–4 are real buffer lines but **not selectable** (see §7 cursor rules). Separators between blocks are rendered as **`virt_lines`** (not real lines), so they never take a cursor position.

---

## 4. Columns (cells)

Body line = `<gutter><milestone cell><issue part>`.

| Part | Width (cells) | Content |
|---|---|---|
| Left edge | 2 | `▎ ` — `GitlabMilestoneEdgeActive` if the cursor is inside this block, else `GitlabMilestoneEdge`. Blank for top-level rows. |
| Milestone cell | 28 | see §5 |
| Cursor mark | 2 | `▌ ` on the cursor line only (`GitlabCursorMark`), else 2 spaces |
| IID | 6 | `#214` + padding, `GitlabIid` |
| Title | flexible (rest) | issue title, truncated with `…` |
| Labels | 32 | `~name` per label, space separated, truncated with `…` |
| Assignee | 17 | `@username` (first assignee; `+N` suffix if more), or `unassigned` in `GitlabUnassigned` |
| State | 10 | `● Open` (`GitlabStateOpened`) / `✓ Closed` (`GitlabStateClosed`) |

Rules:

- Leave **2 cells of gap** between columns.
- Title gets whatever is left; minimum 20 cells.
- **Narrow windows:** if the title would drop below 20 cells, first hide **Labels**, then **Assignee**, then shrink the milestone cell to 20. Column header follows the same visibility.
- Truncate by **display width** (`vim.fn.strdisplaywidth`, `vim.fn.strcharpart`), never by byte length. Several glyphs are multi-byte (`▰ ▱ ● ✓ … ▎ ▌ ─ ❯`).

---

## 5. Grouping, ordering, block rendering

### Blocks

1. **Top-level issues** (no milestone): each issue is its **own block** of one line. Milestone cell shows `—` (`GitlabEmpty`), indented to where milestone text starts. A separator follows each block.
2. **Milestone blocks**: one per milestone that has ≥ 1 issue in the current tab/filter. Issues listed one per line. The milestone cell is drawn on the block's **first three lines**:
   - line 1: `%<title>` — the `%` plus the first word in `GitlabMilestoneName`, the rest in `GitlabMilestoneTitle` (sample titles look like `2026.11 Patch cycle`). Truncate with `…`.
   - line 2: due text (see below).
   - line 3: progress bar — 10 cells of `▰` (closed share, `GitlabProgressDone`) and `▱` (rest, `GitlabProgressTodo`), then ` <closed>/<total>` (`GitlabProgressText`).
   - If a block has fewer than 3 issues, append **filler lines** (non-selectable, issue part empty) so the cell fits.
   - Lines 4+ of the cell are blank.
   - The left edge `▎` spans every line of the block, filler lines included.

### Due text (milestone)

| Case | Text | Highlight |
|---|---|---|
| due in > 7 days | `due Nov 20 · in 12d` | `GitlabDue` |
| due in 0–7 days | `due Nov 12 · in 4d` (`today` for 0) | `GitlabDueSoon` |
| past due, still open | `due Nov 06 · 2d late` | `GitlabDueOverdue` |
| no due date | `no due date` | `GitlabEmpty` |

Date format `%b %d`; add the year if not the current year.

### Progress

`closed/total` counts **all** issues of the milestone, regardless of the active tab or the filter (the milestone's real progress). Use milestone issue stats from the API if available; otherwise compute from fetched issues. If that needs an extra request, say so in the plan.

### Ordering (defaults, configurable)

- Top-level issues first, sorted by `updated_at` desc.
- Then milestones by `due_date` asc (no due date last), ties by title.
- Issues inside a milestone: `due_date` asc (no due last), ties by `iid` desc.

---

## 6. Highlight groups

Define all with `default = true` so users and colourschemes can override. The hex values are what the mockup used (Tokyo Night) — **for reference only, don't hard-code them**.

| Group | Default link | Mockup colour |
|---|---|---|
| `GitlabPickerBorder` | `FloatBorder` | #3b4261 |
| `GitlabPickerBorderActive` | `Function` | #7aa2f7 (accent) |
| `GitlabPickerTitle` | `FloatTitle` | #c0caf5 bold |
| `GitlabPickerFooter` | `Function` | accent; `[I]` / `[i]` bold |
| `GitlabPickerPrompt` | `Function` | accent `❯` |
| `GitlabTab` | `Comment` | #a9b1d6 |
| `GitlabTabActive` | `PmenuSel` | accent bg, dark fg, bold |
| `GitlabColumnHeader` | `Title` | #8a90b8 semibold |
| `GitlabSeparator` | `WinSeparator` | #292e42 |
| `GitlabMilestoneEdge` | `WinSeparator` | #3b4261 |
| `GitlabMilestoneEdgeActive` | `Function` | accent |
| `GitlabMilestoneName` | `Special` | #7dcfff bold |
| `GitlabMilestoneTitle` | `Bold` (create it if missing) | #c0caf5 bold |
| `GitlabDue` | `Normal` | #c0caf5 |
| `GitlabDueSoon` | `DiagnosticWarn` | #e0af68 |
| `GitlabDueOverdue` | `DiagnosticError` | #f7768e |
| `GitlabProgressDone` | `DiagnosticOk` | #9ece6a |
| `GitlabProgressTodo` | `NonText` | #3b4261 |
| `GitlabProgressText` | `Comment` | #a9b1d6 |
| `GitlabIid` | `Comment` | #8a90b8 |
| `GitlabUnassigned` | `Comment` | #8a90b8 |
| `GitlabEmpty` | `NonText` | #545c7e |
| `GitlabStateOpened` | `DiagnosticOk` | #9ece6a |
| `GitlabStateClosed` | `Statement` | #bb9af7 |
| `GitlabCursorMark` | `Function` | accent |
| Cursor line | `CursorLine` (window-local) | #283457 |

**Labels:** use each GitLab label's own colour from the API (`label.color`). Create groups on demand, e.g. `GitlabLabel_<hex>` with `fg = label.color`, cached. Fallback `Comment`. Re-create on `ColorScheme`.

Apply highlights with extmarks in one namespace. Compute **byte** columns for `col`/`end_col` from the rendered strings; display columns are only for layout.

---

## 7. Interaction

### Cursor rules (Table)

- Only **issue lines** are selectable. Tabs line, header, separator and filler lines are skipped.
- Remap `j`/`k`/`<Down>`/`<Up>`/`gg`/`G` to jump between selectable lines; clamp on `CursorMoved` as a safety net.
- On cursor move: update the `▌` mark and re-highlight the active milestone edge (cheap: only the old and new block).
- Keep the selected issue (by `iid`) across re-renders (filter, tab switch, refresh). If it disappears, select the nearest remaining line.

### Keymaps

| Key | Where | Action |
|---|---|---|
| `/` | Table | focus Filter (insert mode at end) |
| `<CR>` | Filter | back to Table, keep filter |
| `<esc><esc` | Filter | clear filter, back to Table |
| `i` | Table | inspect issue under cursor |
| `I` | Table | inspect milestone of the issue under cursor (`vim.notify` "No milestone" for top-level issues) |
| `L` / `H` | Table | next / previous state tab (Open → Closed → All) |
| `]m` / `[m` | Table | jump to next / previous milestone block |
| `R` | Table | refresh from API |
| `q` | Table | close the picker |

All keymaps buffer-local, configurable via `setup({ keymaps = { … } })`, and `false` disables one.

"Inspect" opens the issue / milestone detail view (`docs/issue_detail_design_spec.md`, `docs/milestone_detail_design_spec.md`) on top of the picker; `q` comes back.

### Filter syntax

Space-separated tokens, all must match (AND), case-insensitive:

- `~name` → issue has a label containing `name`
- `%name` → milestone title contains `name` (`%none` = top-level only)
- `@user` → an assignee username contains `user` (`@none` = unassigned)
- anything else → substring of title, or `#123` / `123` matches iid

Milestone blocks with no matching issues are hidden. The counter shows `<matching in tab> / <total in tab>`.

### States

- **Loading:** table body shows `Loading issues…` (`Comment`); the tabs line shows `…` instead of counts.
- **Error:** `Failed to load issues: <message>` (`DiagnosticError`) and `R to retry`.
- **Empty:** `No issues match` (`Comment`) under the header.

---

## 9. Acceptance checklist

- [ ] Opens with one command `:Gitlab`) and covers the editor like the mockup; resizes with the editor.
- [ ] Top-level issues come first, each its own block with `—`. There is no "No milestone" header anywhere.
- [ ] Every milestone block shows name, due text and progress in the left column, aligned with its issues.
- [ ] Every column (IID, title, labels, assignee, state) lines up across top-level and milestone rows.
- [ ] Footer `[I] Milestone • [i] Issue` sits in the bottom-left of the table border.
- [ ] Open / Closed / All tabs switch with `<Tab>`; counts are correct.
- [ ] The cursor never lands on non-issue lines; the selection survives re-renders.
- [ ] `model` and `render` have passing headless tests (grouping, ordering, truncation with multi-byte glyphs, narrow-width column hiding).
