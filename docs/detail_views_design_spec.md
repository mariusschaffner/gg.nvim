# Detail views — shared UI spec

The four detail views (issue, milestone, merge request, pipeline) share one foundation. This file describes it; each view has its own spec:

- `docs/issue_detail_design_spec.md`
- `docs/milestone_detail_design_spec.md`
- `docs/mergerequest_detail_design_spec.md`
- `docs/pipeline_detail_design_spec.md`

Phase 1 is **read-only**. Editing (title, description, fields, dates, tasks), conversation (comment, reply, resolve, delete), merge request actions (approve, merge, draft), CI actions (retry, cancel, play), viewed marks and the diff/review view are phase 2. There is no open-in-browser and no yank-URL key.

---

## 1. Screens and navigation

- The picker is the bottom screen of a stack (`gg.ui.components.stack`).
- `i` on a table row pushes the matching detail view; detail views push each other the same way.
- `q` pops back to the screen below. Popping the last detail view returns to the picker with its tab, filter and selection unchanged.
- `Q` closes the whole stack and returns to the window `:Gitlab` started from.
- A covered screen is **hidden**, not closed: its windows stay, with `hide = true`. Its timers are suspended and resume when it is on top again.
- Closing a screen's window any other way, or moving focus to a window outside it, closes the whole stack.

## 2. Windows

```
╭ issues › #214 ────────────────────────────── opened by Ann · updated 2h ago ╮   header (non-focusable)
│                                                                             │
│  ● Open  Rotate Terraform state backend credentials #214                    │
│                                                                             │
│   security   terraform   ◆ 2026.11 Patch cycle  │  ● ○ 1/2 criteria         │
│                                                                             │
╰─────────────────────────────────────────────────────────────────────────────╯

╭  Description   Activity 2  ─────────────────────────╮ ╭──────────────────────╮
│                                                     │ │                      │
│ content of the active tab                           │ │ ASSIGNEE             │   sidebar (34 cols,
│                                                     │ │ (US) User            │   non-focusable)
╰ [i] Edit ───────────────────────────────────────────╯ ╰──────────────────────╯
```

| Window | Content | Notes |
|---|---|---|
| Header | pill, title, `#iid` / `!iid` / `%id`, optional chip row, optional extra block (strips, pipeline graph) | Border title: breadcrumb on the left, meta on the right. Height follows the content, capped at 55% of the editor. |
| Content | the active tab's buffer | Tabs in the border title: the active one bold and bright (`GitlabDetailTabActive`), the others gray, no background. Key hints in the footer, written `[<key>] <description>`. Each tab has its own buffer, so a tab keeps its cursor. Every tab starts with an empty line. |
| Sidebar | labelled fields (UPPERCASE label, values, dividers) | Only at 100 columns or more. Narrower: no sidebar, and a one-line summary in the header. |

- **Spacing:** the header body has an empty line above the title and one at its end; one empty row separates the header from the boxes below; tabs and the sidebar start with an empty line.
- **Borders:** every border of a detail view is gray (`GitlabDetailBorder`), focused or not. The breadcrumb names only the kind and the reference (`issues › #214`), not the group or project.
- **Description tabs** show `[i] Edit`. Editing is phase 2; until then the key says so. Activity tabs show no key hints.
- Rendering is pure: each pane is rendered into a `gg.ui.Doc` (lines, highlights, whole-line backgrounds, per-line metadata), and `gg.ui.detail.host` writes it into the buffer.
- Loading and error states are static text, `Loading…` or the error message. There is no spinner timer.

## 3. Shared keys

| Key | Action |
|---|---|
| `q` | back |
| `Q` | close everything |
| `R` | reload the view |
| `<Tab>` / `<S-Tab>` | next / previous tab |
| `i` / `<CR>` | open the row or card under the cursor |

All keys are configurable in `require("gg.ui").setup({ keymaps = … })`; `false` disables one.

## 4. Look

- Plain Unicode only, no Nerd Font glyphs.
- State pills: ` ● Open ` with the state colour as background. `GitlabPill*` groups use the linked group's foreground, in reverse video.
- Label chips: ` name ` on the label's own colour, with black or white text by luminance (`GitlabChip_<hex>`).
- People: `(XS) Name`, with the initials in the user's stable colour (`GitlabUser1`…`8`).
- Dimmed text is plain gray: `GitlabDetailDim`, the colour of `Comment` without its italic.
- Every colour comes from a highlight group defined with `default = true`.
