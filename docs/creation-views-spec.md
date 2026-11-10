# Creation views (K4 popups) — UI spec

Status: ready to implement
Mockups: `docs/creation_view.png` (PNG export) and `docs/creation_view_helpers/` (HTML exports of the boards **Compact popup K4 · K2 floats + K3 bottom border row** and **K4 · pipeline**).
Where this spec and the mockups disagree, the mockup wins.

Builds on `docs/issue_table_design_spec.md`, `docs/mergerequest_table_design_spec.md` and `docs/pipelines_table_design_spec.md`. Reuse their shared modules: bordered float, highlight setup and the stage/status helpers. The API layer exists. Use it as-is, and ask before changing it.

---

## 1. What it is

One popup design ("K4") for creating GitLab objects from Neovim:

| View | Command (suggested) | Border accent |
|---|---|---|
| New issue | `GitlabCreateIssue` → `Function` (blue) |
| New merge request | `GitlabCreateMR` → `Statement` (purple) |
| New milestone | `GitlabCreateMilestone` → `Special` (cyan) |
| Run pipeline | `GitlabCreatePipeline` → `DiagnosticOk` (green) |

The views should open from the table views of the item. so on the issue & Milestone table there will be a bottom border binding hint "[C] Create Milestone" and "[c] Create Issue". In the merge request table, "[c] Create Merge Request", in the pipeline table "[c] Start Pipeline". the views should only be invokable from there, or from an issue to create a merge request.

---

## 2. Layout

The popup occupies **70 % of the editor width and 70 % of the editor height**, centred (`relative = "editor"`). Recompute on `VimResized`.

Inside that area, floats are stacked top to bottom with one empty row between them (the border labels need the room):

```
╭ ＋ New Merge Request───────────────────────────────────────────────────────╮   title float (1 line)
│ feat(docs): add sprint-3 planning                                          │
╰────────────────────────────────────────────────────────────────────────────╯
╭ [gB] Source ─────────────────────╮ ╭ [gd] Target ─────────────────────────╮   field row (MR / pipeline only)
│ ⎇ test                           │ │ ⎇ master                             │
╰──────────────────────────────────╯ ╰──────────────────────────────────────╯
╭ [i] Edit ──────────────────────────────────────────────────── Issue ───────╮   body float (fills the rest)
│  1 #SCS                                                                    │
│  2                                                                         │
│  3 As the main developer,                                                  │
│  4 I want to █‹what›                                                       │
│  5 So that ‹why›                                                           │
│  …                                                                         │
╰ T template · Tab title ⇄ description · Esc Esc cancel ──────── C-s create ─╯
```

| Float | Height | Border title (left / right) | Footer (left / right) |
|---|---|---|---|
| Title | 1 line | `＋ New <thing>` in the accent colour, bold / — | — |
| Field row (0–2 floats side by side, 2 cells apart, equal width) | 1 line | `[key] Label`, with the key in `GitlabCreateKey` / — | — |
| Body | rest | `[i] Edit` / entity name (`Issue`, `Merge Request`, `Milestone`, `Variables · N`) | hints (§5) / `C-s create` (or `C-s run`) in `GitlabCreateSubmit` |

Details:
- Only the **title float** border uses the accent colour. All other borders use `GitlabPickerBorder`. The float that has focus gets `GitlabPickerBorderActive` (same mechanism as the list views).
- Title text: bold, `GitlabCreateTitle` (links to `Title`).
- **Left and right labels in one border:** `nvim_open_win` takes `title`/`footer` as a list of `{text, hl}` chunks with one `*_pos`. Build left + padding + right as one chunk list, with padding = border width − display width of both labels, and rebuild it on resize. Put this in the shared float module so every view gets it.
- Body float: `number`, `cursorline`, `wrap`, `linebreak`, `signcolumn=no`. Filetype `markdown` for issue, MR and milestone, so treesitter/markdown highlighting applies to `#`, `##`, `**…**`, `- [ ]`.
- `＋`, `⎇`, `‹›`, `⇄` are wide or multi-byte. Measure everything with `strdisplaywidth`.
- Minimum size: if 70 % of the height is less than 14 rows or 70 % of the width is less than 60 columns, clamp to those minimums (or the full editor if it is smaller).

---

## 3. The four views

### 3.1 New issue
- **Fields:** title, description.
- **Description:** empty placeholder.
- **Cursor:** if the title is empty, start in the title float in Insert mode. Otherwise start on the first placeholder in the description.
- **Submit:** create the issue with title and description. Optional pre-set values passed by the caller (e.g. milestone or labels when opened from a milestone block) are sent along but not shown.

### 3.2 New merge request
- **Field row:** `[gB] Source` (default: the current git branch, `⎇ <name>` in `GitlabBranchSource`) and `[gd] Target` (default: the project's default branch, `GitlabBranchTarget`).
- **Title prefill:** `Merge <source> into <target>`. If the source branch starts with an issue number (`22-some-feature`), use that issue's title instead and prefill `Closes #22` as the first description line.
- **Description:** the default MR template (§4).
- **Picker:** `gB` / `gd` open a branch picker. Use a small float list with live filtering (reuse the filter prompt component if it fits), and fall back to `vim.ui.select`.
- **Submit:** create the MR (source, target, title, description).
- **Validation:**
  - source ≠ target
  - the source branch exists on the remote; if it doesn't, offer to push it first: `y/N`, using `git push -u origin <branch>`
  - an MR doesn't already exist for this source; if one does, show its `!iid` and offer to open it instead

### 3.3 New milestone
- **Fields:** title (starts empty, cursor here with placeholder virtual text `title`), description.
- **Description:** empty placeholder.
- **Submit:** create the milestone with title and description. See open question 1 about dates.

### 3.4 Run pipeline (board "K4 · pipeline")
- **Title float:** label `▶ Run pipeline`, text `Run pipeline for ⎇ <ref>`. Read-only; it follows the ref field.
- **Field row:** one float, `[gB] Branch or tag`. Shows `⎇ <ref>` plus, dimmed, the short SHA and commit title of that ref. Default: the current git branch if it exists on the remote, else the default branch. The picker lists branches and tags.
- **Body = Variables editor** (border title right: `Variables · N`):
  - A header line `Key  Value  Type` (virtual line, not editable).
  - One line per variable, written as `KEY = value`. Parse on submit: key = text before the first `=`, trimmed; value = the rest, trimmed. Blank lines are ignored.
  - **Type** per line is shown as right-aligned virtual text, `var` (`Comment`) or `file` (`GitlabCreateKey`). `t` toggles it for the line under the cursor. Store it in an extmark-keyed table so it survives edits.
  - **Prefill:** variables defined for manual runs in `.gitlab-ci.yml`, with their default value and dimmed virtual text `default from .gitlab-ci.yml`. If the API can't provide them (e.g. GraphQL `ciConfigVariables(ref:)`), start empty and say so in the plan.
  - `a` adds a new line `‹KEY› = ‹value›` below the cursor and enters Insert on the key. `dd` removes the line (normal Vim).
  - **Validation:** keys match `^[A-Za-z_][A-Za-z0-9_]*$` and appear once. Bad lines get a diagnostic and block submit.
- **Submit:** `C-s run` creates the pipeline (ref + variables), then closes the popup and opens the pipelines view with the new pipeline selected (if that view exists).

---

## 5. Keys

All keys are buffer-local to the popup's buffers and configurable.

| Key | Mode | Action |
|---|---|---|
| `Tab` / `S-Tab` | Normal (and Insert in the title) | next / previous float: title → field(s) → body → title |
| `i` | Normal, body | edit (normal Vim) |
| `gB` / `gd` | Normal, only on merge request | open source / target picker (MR); `gB` = ref picker (pipeline) |
| `a` / `t` | Normal, variables body | add variable / toggle var ⇄ file |
| `<C-n>` / `<C-p>` | Normal + Insert | next / previous placeholder |
| `<C-s>` | Normal + Insert | submit (create / run) |
| `Esc Esc` | Normal | cancel. Within `timeoutlen` of the first `Esc`. If anything changed, confirm `Discard changes? y/N` |

The bottom-left footer of the body shows the hints for the view:
- issue / MR / milestone: `T template · Tab title ⇄ description · Esc Esc cancel`
- pipeline: `a add · dd remove · t var ⇄ file · Esc Esc cancel`

Keys are drawn in `GitlabCreateKey` (links to `DiagnosticWarn`, as in the mockup), the rest in `Comment`.

---

## 6. Submit, feedback, errors

- On `<C-s>`, the bottom-right label changes to `creating…` (or `running…`) and further edits are blocked. The API call is async and never blocks the UI.
- **Success:** after creation the item should be opened in its detail view.
- **Error:** keep the popup and its contents. Show the error in the bottom-right label (`GitlabCreateError` → `DiagnosticError`), plus `vim.notify` with the full message. Field-level errors from the API (e.g. a title that is too long) are shown as diagnostics in the matching float.
- Drafts: if the popup is cancelled with changes discarded, nothing is kept. Optional: keep the last unsent issue/MR draft in memory for the session, and offer to restore it the next time the same view opens.

---

## 7. Highlight groups (new)

| Group | Default link | Mockup |
|---|---|---|
| `GitlabCreateIssue` | `Function` | #7aa2f7 |
| `GitlabCreateMR` | `Statement` | #bb9af7 |
| `GitlabCreateMilestone` | `Special` | #7dcfff |
| `GitlabCreatePipeline` | `DiagnosticOk` | #9ece6a |
| `GitlabCreateTitle` | `Title` (bold) | #e6eaff |
| `GitlabCreateKey` | `DiagnosticWarn` | #e0af68 |
| `GitlabCreateSubmit` | `DiagnosticOk` | #9ece6a |
| `GitlabCreateError` | `DiagnosticError` | #f7768e |
| `GitlabCreatePlaceholder` | `Comment` + italic | #7f87ad |

All `default = true`. Reuse the existing border, branch and cursor-line groups.

---

## 9. Acceptance checklist

- [ ] All four views open, take 70 % × 70 % of the editor, are centred and resize correctly.
- [ ] They look like the mockups: accent title float, field row, body with line numbers, left/right labels in the borders, footer hints bottom-left and the submit label bottom-right.
- [ ] `Tab` cycles floats; `Esc Esc` cancels (with a confirm if anything changed); `<C-s>` submits from Normal and Insert.
- [ ] MR: branch defaults, `Closes #N` prefill, source/target pickers, the existing-MR and unpushed-branch checks.
- [ ] Pipeline: ref picker, variables add/remove/toggle type, validation, prefilled CI variables if the API offers them, opens the new pipeline after running.
- [ ] Errors keep the popup open and show where they belong.
- [ ] Headless tests for all pure modules.

---

## 10. Open questions (decide before or during planning)

1. **Milestone dates:** should `**Zeitplan**: dd.mm.yyyy – dd.mm.yyyy` also set the milestone's `start_date` / `due_date`? Or should there be two field floats `[s] Start` / `[d] Due` in the field row instead? -> two floats similar to the merge request with the source and target branch
2. **Templates:** should the issue view always start with the default template, or with an empty description when the project has no `Default` template? -> dont use templates at all
3. **Opening from lists:** should `n` in the issues picker open "New issue" with the milestone of the block under the cursor pre-set? -> yes, but the creation view of the issue picker should not display a milestone field, it should only be set in the background, and the creation key will be "c"
4. **MR title:** should a Draft prefix (`Draft: `) be the default? -> No
