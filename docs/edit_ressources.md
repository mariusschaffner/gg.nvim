# Editing resources in the detail views — migration plan

> Status: all phases done (see "Implementation notes" at the end).

## Context

The read-only detail views (issue, milestone, merge request, pipeline) are
done. atlas.nvim could also **change** what they show: titles, descriptions,
tasks, fields, comments, states, merge request actions and CI actions. This
plan brings that into gg.nvim.

### Port or build new?

**Build new; port the behaviour.**

- atlas edits inside its own window model: tabpages, a header split, a
  statusline for notices, and provider "capabilities". gg has none of these.
  gg has a screen stack, a float host, pure documents (`gg.ui.lib.doc`) and a
  typed API facade.
- CLAUDE.md says the old plugin is a reference for required behaviour, not
  code to copy.
- The gg API already covers almost every write (see §2), so the work is the
  UI layer: editing components, the wiring per view, and tests.

### Decided with you

| Topic | Decision |
|---|---|
| Fields (assignees, reviewers, labels, milestone, target branch, dates) | **atlas inline overlay**: a one-line float laid over the field, comma-separated values, async completion with `<Tab>` / `<S-Tab>`, unknown values dropped with a warning |
| Text (title, description, comments, replies) | **atlas inline**: description edited in place in its tab; title in a one-line overlay on the header; comments in a docked composer at the bottom of Activity; replies in a frame under their thread; comment edits in place of the body |
| Scope beyond fields, text and comments | MR actions; pipeline and job actions; creating a branch and a merge request from an issue |
| Not in scope | Creating new issues or milestones from the tables; the diff/review view |
| Keys | atlas keys, with the field keys shown right-aligned in the sidebar labels (`ASSIGNEE  ga`) |

---

## 1. Required behaviour (from atlas)

### Issue

| Key | What | API |
|---|---|---|
| `gt` | Title, in an overlay on the header title. Empty or unchanged does nothing. Open issues only. | `issues.update{title}` |
| `i` (Description) | Edit the description in place. Refetch it before editing so the edit starts from the current text. | `issues.update{description}` |
| `x` (Description) | On a task line, toggle `[ ]` / `[x]`. Optimistic: the header progress updates at once; roll back on error. Shows a right-aligned `x toggle` virtual-text hint on task lines. | `issues.update{description}` |
| `ga` | Assignees, multi-value. Completion from project members (`Name (@user)`). Open issues only. | `issues.update{assignee_ids}` |
| `gl` | Labels, multi-value. Completion from the project's labels. Any state. | `issues.update{add_labels, remove_labels}` |
| `gM` | Milestone, single value. Completion from the active milestones. Unknown text → "Unknown milestone"; empty clears it. | `issues.update{milestone_id \| false}` |
| `gs` / `gd` | Start / due date, ISO text over the dates field. Empty clears. Both dates are sent together. | `work_items.update_dates` |
| `gb` | Create a branch: pick the source (default branch first), name defaults to `<iid>-<slug(title)>` (≤ 50 characters). Refused when the issue is closed or a branch is already linked. | `branches.list`, `branches.create` |
| `gP` | Create a merge request for the issue (§4.7). | `merge_requests.create` |
| `A` | Actions menu: Close issue / Reopen issue. | `issues.update{state_event}` |

**Activity tab** (shared with merge requests):

| Key | What |
|---|---|
| `i` | Comment: expands the docked composer. |
| `gc` | Reply to the thread under the cursor. Replying to someone else's comment seeds `@user `. |
| `gE` | Edit your own comment, in place of its body. |
| `gD` | Delete your own comment, after a `[y/N]` confirmation. A root comment with replies is marked deleted and kept so the thread stays intact. |
| `gX` | Resolve / unresolve the thread. |
| `<C-r>` | In the reply composer: post and resolve. |
| `<CR>` | Expand a run or a folded thread (this key no longer shares `i`). |

- **Composers:** `<C-s>` posts. `<Esc>` in normal mode cancels.
- **Mentions:** `@` completes from the reporter, the assignees and everyone who commented.
- **After a change:** the activity is updated in place (no full refetch) and the cursor follows the new or edited comment. A closed issue offers no commenting.

### Milestone

| Key | What | API |
|---|---|---|
| `gt` | Title; empty is rejected ("Title cannot be empty"). | `milestones.update{title}` |
| `i` (Description) | Edit the description in place. | `milestones.update{description}` |
| `gs` / `gd` | Start / due date, in an overlay on the date labels of the header strip (or on `no dates`). Empty clears. | `milestones.update{start_date, due_date}` |
| `A` | Close milestone / Reopen milestone. | `milestones.update{state_event = close \| activate}` |

### Merge request

| Key | What | API |
|---|---|---|
| `gt`, `i`, `x` | As for issues. Only while the MR is open or a draft. | `merge_requests.update` |
| `ga` | Assignees. | `merge_requests.update` |
| `gr` | Reviewers. | `merge_requests.update{reviewer_ids}` |
| `gl` | Labels. | `merge_requests.update` |
| `gM` | Milestone. | `merge_requests.update` |
| `gB` | Target branch, single value. Completion from branches. | `merge_requests.update{target_branch}` |
| `gb` | Toggle "delete source branch" (ON MERGE in the sidebar). | `merge_requests.update{remove_source_branch}` |
| Activity | As for issues; resolving works on MR threads too. | `notes.*` |

`A`, the MR actions menu:

- **Approve** / **Unapprove** (`reviews.approve`, new `reviews.unapprove`).
- **Merge**, only when open and not a draft, after the confirmation `Merge !iid into <target>? [y/N]`.
  - Squash and delete-source-branch come from the MR's own flags, else from the defaults in config.
  - `merge_requests.merge`.
- **Close** (with confirmation) / **Reopen** (`merge_requests.update{state_event}`).
- **Mark as ready** / **Mark as draft** (`merge_requests.update{draft}`).

### Pipeline (graph mode)

| Key | What | API |
|---|---|---|
| `r` | Retry the selected job; only when it is retryable, otherwise a warning. | `jobs.retry` |
| `p` | Play a manual job; only when it is playable ("is blocked" otherwise). | `jobs.play` |
| `X` | Cancel the selected job, after a `[y/N]` confirmation. | `jobs.cancel` |
| `gR` | Retry the failed jobs of the pipeline. `R` stays "reload" in gg. | `pipelines.retry` |
| `gX` | Cancel the pipeline, after a `[y/N]` confirmation. | `pipelines.cancel` |

- **After an action:** refresh at once and keep polling for 10 s more, so the pipeline turning active again is picked up.
- **Retried jobs:** the selection follows a retried job by stage and job name. This already works.
- **Hints:** the job hints in the header's bottom border appear only when the action applies (`[r] Retry` only for a failed job, …). Pipeline hints appear only for a failed or active pipeline.

### Shared editing look and feel

- **Borders:** gray normally (as decided before), **orange while editing** (`GitlabDetailBorderEditing`, a new group). While a field is being edited, its sidebar label turns orange.
- **Footers while editing:** `[<C-s>] Save • [<Esc>] Cancel`. Description tabs keep `[i] Edit`. Field keys show in the sidebar labels.
- **Notices:** `gg.ui: Updating title…` → `Title updated`, or the error message (with `vim.log.levels.ERROR`). These go through `vim.notify`, because gg has no statusline.
- **Disabled actions:** an action that does not apply (a closed issue, a merged MR) gives a short warning instead of doing nothing silently. Its hint is hidden.

---

## 2. API layer

Almost everything exists. Facade functions to use:

| Area | Functions |
|---|---|
| Issues | `issues.update`, `work_items.update_dates` |
| Milestones | `milestones.update` |
| Merge requests | `merge_requests.update` (incl. `draft`, `reviewer_ids`, `remove_source_branch`), `merge_requests.merge`, `merge_requests.create` |
| Reviews | `reviews.approve` |
| Comments | `notes.add`, `reply`, `edit`, `delete`, `set_resolved` |
| Branches | `branches.list`, `branches.create` |
| Completion | `labels.list_all`, `users.project_members_all`, `milestones.list_all`, `branches.list` |
| CI | `jobs.retry`, `jobs.cancel`, `jobs.play`, `pipelines.retry`, `pipelines.cancel` |

**Gaps:** these change the API. They need an explicit go-ahead before phase 1, as CLAUDE.md requires.

1. **`reviews.unapprove`:** a new function, REST `POST /projects/:id/merge_requests/:iid/unapprove`. Check against docs.gitlab.com, add fixture tests.
2. **Clearing milestone dates:** `MilestoneUpdateArgs.start_date` / `due_date` accept `false` to clear (sent as `null`), like `work_items.update_dates`. This changes a signature.
3. **Comment deletion:** check whether a root comment with replies can be deleted without losing the thread (atlas kept it). If the API cannot do that, keep the comment and show it as `(deleted comment)` locally.

---

## 3. Architecture (gg.ui)

```
ui/components/
  inline_edit.lua     a tab buffer becomes editable raw text (description)
  field_edit.lua      one-line overlay float over a region, completion, multi-value
  composer.lua        multi-line markdown float (dock / reply / edit frames), mentions
  confirm.lua         [y/N] confirmation and the A actions menu (vim.ui.input / vim.ui.select)
ui/detail/
  edit.lua            mutation runner: notice -> task -> apply result or roll back -> re-render
  regions.lua         (pure) where fields sit in the rendered docs, for anchoring overlays
  <kind>/edits.lua    (pure) payloads: label add/remove diff, usernames -> ids,
                      task toggle, branch slug, "Closes #iid", action availability
  <kind>/view.lua     wires keys -> overlays -> edit.run
  merge_request/create_view.lua  the "new merge request" form screen (§4.7)
```

### Regions

The overlays need to know where a field is drawn.

- The pure renderers record **regions** in their docs, using the existing `rows` metadata plus a `regions` table: `{ id = { row, col, width } }`.
  - `sidebar.build` marks each field's value lines.
  - `header.build` marks the title.
  - `timeline.strip` marks the date labels.
- The host turns a region into screen coordinates with `screenpos()`, as atlas did, so scrolling is handled.

### Mutation runner (`detail/edit.lua`)

`edit.run{ what, task, apply, rollback?, refresh? }` does the following:

1. Shows "Updating <what>…".
2. Runs the gg task.
3. On success, calls `apply(result)`. Usually the returned model replaces the view's copy, so there is no refetch.
4. Re-renders, then shows "<What> updated".
5. On error, calls `rollback()` if given (optimistic task toggle) and notifies the error.

Two more rules:

- **Activity:** a change that creates system notes (labels, assignees, state, …) reloads the Activity tab once it has loaded.
- **Picker freshness:** an edit marks the screens below as changed (`stack:changed(kind)`). When the picker resumes it reloads that view, so the table shows the new title or labels after `q`. Detail views below the top refresh the same way when they resume.

### Editing state

- **While inline editing:** the host stops re-rendering that tab, so spinners or polls cannot overwrite the text being edited. The tab-switch and back keys are blocked, and `<Esc>` / `<C-s>` end the edit first.
- **One edit at a time per view:** a second overlay closes the first one, and its edit is lost (as in atlas).

### Keymaps (config)

- **New keymaps**, all `false`-able:

  | Keymap | Default |
  |---|---|
  | `edit_title` | `gt` |
  | `toggle_task` | `x` |
  | `edit_assignees` | `ga` |
  | `edit_reviewers` | `gr` |
  | `edit_labels` | `gl` |
  | `edit_milestone` | `gM` |
  | `edit_target_branch` | `gB` |
  | `edit_start_date` | `gs` |
  | `edit_due_date` | `gd` |
  | `toggle_delete_branch` | `gb` (MR) |
  | `create_branch` | `gb` (issue) |
  | `create_mr` | `gP` |
  | `comment` | `i` (Activity) |
  | `reply` | `gc` |
  | `edit_comment` | `gE` |
  | `delete_comment` | `gD` |
  | `toggle_resolved` | `gX` |
  | `submit` | `<C-s>` |
  | `submit_resolve` | `<C-r>` |
  | `cancel_edit` | `<Esc>` |
  | `actions` | `A` |
  | `retry_job` | `r` |
  | `play_job` | `p` |
  | `cancel_job` | `X` |
  | `retry_pipeline` | `gR` |
  | `cancel_pipeline` | `gX` (pipeline view) |
  | `complete_next` / `complete_prev` | `<Tab>` / `<S-Tab>` |

- **Existing keymaps:**
  - `edit` (`i`) stops being a placeholder.
  - `open_item` in Activity becomes `<CR>` only, because `i` there means comment.
- **New options:** `merge_squash` (nil = the MR's own setting) and `merge_delete_source_branch` (nil = the MR's own setting).

---

## 4. Phases

Each phase ends with `make test` green, its spec in `docs/*_detail_design_spec.md` updated, and `doc/gg.txt` updated.

1. **Foundation.** ✅ Done:
   - `gg.reviews.unapprove` (`POST …/unapprove`, 201 with the approval
     state, per docs.gitlab.com).
   - `gg.milestones.update` takes `false` to clear `start_date` /
     `due_date`, sent as JSON `null`. docs.gitlab.com says nothing about
     clearing; check it against a real instance.
   - The new keymaps and `merge_squash` / `merge_delete_source_branch` are
     in `ui/config.lua`. The keys do nothing yet; they are wired in
     phases 2–7.
   - `GitlabDetailBorderEditing`, `GitlabDetailLabelEditing`,
     `GitlabFieldEdit` and `GitlabEditPlaceholder` highlight groups.
   - Regions: `doc:region`, `sidebar` `id` / `ids` / `line_ids`, the
     header's `title`, the milestone strip's `start_date` / `due_date`.
     `host:region_pos(pane, id)` gives screen coordinates.
   - `ui/detail/edit.lua` (`run`, `refuse`, `messages`) and
     `ui/components/confirm.lua` (`ask`, `menu`).
   - `stack:changed(kind)`: the screens below refresh when shown again.
     The picker reloads only the views a kind affects
     (`picker.AFFECTS`).

   The original plan for this phase:
   - Keymaps and options in `ui/config.lua`; the `GitlabDetailBorderEditing` group.
   - Regions in `sidebar` / `header` / `timeline`, with pure tests.
   - `detail/edit.lua`, `components/confirm.lua`, and `stack:changed` + picker reload on resume.
   - API gaps (§2) after your go-ahead.
2. **Text in place.**
   - `components/inline_edit.lua`: description editing (issue, MR, milestone), with a refetch before the edit.
   - The title overlay (`field_edit` in single-line mode).
   - Task toggle `x` with rollback; the markdown source-line mapping already exists (`rows[l].src`).
3. **Fields.**
   - `components/field_edit.lua`: overlay, multi-value parsing, debounced (150 ms) async completion with `vim.fn.complete`, unknown-value warnings.
   - Fields: labels, assignees, reviewers, milestone, target branch, issue dates (sidebar), milestone dates (header strip), and the MR delete-source-branch toggle.
   - Sidebar hints: `ASSIGNEE  ga`, `START gs | DUE gd`, …, shown only where the edit applies.
4. **Comments.**
   - `components/composer.lua`:
     - **Dock:** collapsed to one row (`(XX) › write a new comment…   [i] Comment`), expanded to 3–10 rows with a mode badge.
     - **Reply frame:** under its thread, with the `└─` guide; `<C-r>` posts and resolves; `● unsaved` once changed.
     - **Edit frame:** in place of the comment body.
     - `@` mention completion; a placeholder text while empty.
   - `gc` `gE` `gD` `gX` on the Activity tab of issues and MRs, with cursor hints on comment rows (`gc reply · gE edit · gD delete · gX resolve`; edit and delete only on your own comments).
5. **State and MR actions.** The `A` menus: issue close/reopen; milestone close/reopen; MR approve/unapprove, merge (confirmation), close/reopen, ready/draft. The readiness strip and pill re-render from the results.
6. **Pipeline and job actions.**
   - `r` `p` `X` `gR` `gX` with confirmations, an immediate refresh and the 10 s grace polling.
   - Conditional hints in the header border.
7. **Create from an issue.**
   - **`gb` (create branch):** `vim.ui.select` for the source branch, then `vim.ui.input` for the name. The new branch appears under DEVELOPMENT.
   - **`gP` (new merge request):** pushes a **new merge request** screen, a form in the detail host. Its fields are prefilled:
     - source: the issue's branch, else a choice;
     - target: the default branch;
     - title: `Draft: Resolve "<issue title>"`;
     - description: `Closes #iid`;
     - assignee: you.
   - The form's fields are edited with the same overlays. `<C-s>` creates the merge request and replaces the form with the new MR's detail view.
8. **Docs.** `doc/gg.txt` (keys, options, behaviour), the five detail specs, README, and CLAUDE.md (the new components and the "edits go through `detail/edit.lua`" rule).

## 5. Tests

- **Pure:**
  - Regions; payload diffs (labels add/remove, usernames → ids, unknown values).
  - Task toggle on source lines; branch slug; "Closes #iid".
  - Action availability per state; mention candidates.
- **Components with real windows** (headless, `feedkeys`):
  - `inline_edit`: save, cancel, edit while polling.
  - `field_edit`: typing, completion, `<Tab>`, unknown values.
  - `composer`: grow, submit, cancel, mentions.
- **Views with the fake backend:** every mutation asserts its request (`fake:requests()`, `body_contains`), the re-render, the notice and rollback on error. Write fixtures come from the docs.gitlab.com examples, as the existing `write.json` files do.
- **Picker freshness:** edit a title in a detail view, `q`, and the table row shows it.
- **Manual check against a real project** (not possible from here): every key on a scratch issue / MR / milestone and a test pipeline.

## 6. Open points for review

- The API gaps in §2 (new `reviews.unapprove`; `false` to clear milestone dates).
- The orange border while editing, the one exception to "all borders gray".
- Notices through `vim.notify`; atlas used its statusline.

## Implementation notes

What was built, and where it differs from the plan above:

- **Text in place** (`components/text_edit.lua`): the description is edited
  in a separate markdown buffer swapped into the content window, not in the
  tab buffer itself. Only `submit` / `cancel_edit` are mapped in it, so the
  view's own keys (`i`, `x`, `q`, the tab keys) cannot fire while editing.
- **Field overlays** (`components/field_edit.lua`, `detail/fields.lua`): as
  planned. The project's members, labels and active milestones are loaded
  once per view on the first overlay that needs them (`editing.source`);
  target branches are searched as you type.
- **Comments** (`components/composer.lua`, `activity/view.lua`): the
  collapsed box is the last line of the timeline; `i` opens the composer
  docked at the bottom of the content window, replies open below their
  thread, edits over their comment. After a post the activity is fetched
  again (one request) and the cursor follows the new or edited comment,
  instead of patching the list locally.
- **Deleting a root comment** with replies: the note is deleted through the
  API and the activity reloads; GitLab keeps the remaining thread.
- **Merge** squash / delete-source-branch: `merge_squash` /
  `merge_delete_source_branch` win, else the merge request's own flags.
- **Pipeline actions**: `r` / `p` / `X` only in graph mode; `gR` / `gX`
  everywhere in the view.
- **Not verified against a real GitLab**: clearing milestone dates sends
  `null`; GitLab's docs do not describe clearing.
