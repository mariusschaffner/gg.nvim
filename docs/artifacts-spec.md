# Artifacts tree view — UI spec

Mockups:
- docs/artifacts-design.png
- docs/artifacts-design-helpers/

Where this spec and the mockup disagree, **the mockup wins**.

Builds on issues, mr, pipelines. becomes a ne "tab" in the global tab cycle between them.
Reuse their shared modules: bordered float, filter prompt, cursor rules, highlight setup and the pipeline status icons. The API layer exists. Use it as-is, and ask before changing it.

---

## 1. What it is

A full-editor float that shows the project's **CI job artifacts as a file tree**:

```
pipeline  →  job › artifact  →  folders  →  files
```

You can browse into archives, download a file or a whole artifact, open a file in a read-only buffer, or copy its path.

```
╭ [/] Filter ──────────────────────────────────────────────────────────────────────────────────────────╮
│ ❯ █ Filter                                                                                           │
╰──────────────────────────────────────────────────────────────────────────────────────────────────────╯
╭ Table ───────────────────────────────────────────────────────────────────────────────────────────────╮
│   Name                                                                              Size   Expires   │
│ ──────────────────────────────────────────────────────────────────────────────────────────────────── │
│   ▾ ✗ #4819  feat/oci-edge-lb  · 1h ago  · 2 artifacts                            322 KB             │
│   ├── test:tflint  › tflint.json                                                   12 KB   in 6d     │
│   ╰── test:checkov  › results.sarif                                               310 KB   in 6d     │
│   ▸ ▸ #4817  feat/rotate-tf-creds  · 2h ago  · 1 artifact                          1.8 MB            │
│   ▸ ✓ #4815  feat/dns01-wildcard  · 3h ago  · 2 artifacts                          3.3 MB            │
│   ▾ ✓ #4812  main  · 8h ago  · 2 artifacts                                        12.4 MB            │
│   ├── ▾ build:package  › artifacts.zip                                            12.4 MB   kept     │
│   │   ├── ▾ dist/                                                                  9.8 MB            │
│   │   │   ├── infra-automation-1.4.2.tar.gz                                        9.8 MB            │
│   │   │   ╰── checksums.sha256                                                      1 KB             │
│   │   ├── ▸ modules/  4 files                                                      10 KB             │
│   │   ├── ▾ reports/                                                              198 KB             │
│ ▌ │   │   ├── terraform-docs.md                                                    38 KB             │
│   │   │   ╰── coverage.xml                                                        160 KB             │
│   │   ├── build.log                                                               310 KB             │
│   │   ╰── VERSION                                                                   6 B              │
│   ╰── build:vars  › build.env                                                      512 B   in 29d    │
│   ▸ ✓ #4808  main  · 1d ago  · 1 artifact                                          46 KB             │
╰ [d] Download • [o] Open in buffer • [y] Copy path ───────────────────────────────────────────────────╯
```

---

## 2. Windows & layout

The same two-float layout as the other list views:

| Window | Title | Footer |
|---|---|---|
| Filter | ` [/] Filter ` | — (placeholder `Filter`, no counter) |
| Table | ` Table ` | ` [d] Download • [o] Open in buffer • [y] Copy path ` (bottom-left) |

The table has **no tabs line**; the mockup removed it. Buffer lines:

1. **Column header** (`GitlabColumnHeader`): `Name` · `Size` (right-aligned) · `Expires`
2. **Separator** `─`
3. **Tree rows.** Between two pipeline roots, a thin non-selectable separator drawn as `virt_lines` (`GitlabSeparator`).

---

## 3. Columns

| Column | Width (cells) | Notes |
|---|---|---|
| Cursor mark | 2 | `▌ ` on the cursor line (`GitlabCursorMark`) |
| Name | flexible (min 30) | tree guides + chevron + content (§4), truncated with `…` by display width |
| Size | 10, right-aligned | human-readable: `6 B`, `512 B`, `12 KB`, `1.8 MB`, `12.4 GB`. Base 1024, one decimal from MB up |
| Expires | 10 | `kept` · `in 6d` · `in 1d` · `today` · `expired` (§5) |

Two cells gap between columns. Narrow windows: hide Expires first, then Size.

---

## 4. Tree

### Guides ("rounded branches" style)

Each depth level adds one 4-cell segment, in `GitlabTreeGuide` (links to `NonText`):

| Situation | Segment |
|---|---|
| ancestor level, more siblings follow | `│   ` |
| ancestor level, ancestor was the last child | `    ` |
| this node, more siblings follow | `├── ` |
| this node, last child | `╰── ` |

Pipeline roots have no guides. Nodes with children show a chevron after the guide: `▾ ` (open) or `▸ ` (closed), in `GitlabTreeChevron` (links to `Function`). Leaves have no chevron.

### Node types

| Type | Content (left → right) | Size | Expires | Children |
|---|---|---|---|---|
| **Pipeline** (root) | chevron, status icon (shared pipeline icons: `✓` `✗` `◐` `▸` `⊘`), `#<id>` bold, ref (default branch `GitlabRefDefault`, others `GitlabBranchSource`, tags `GitlabRefTag`), dimmed `· <relative time> · <N> artifact(s)` | sum of its artifacts | — | its artifacts |
| **Artifact** | `<job name>` (`GitlabArtifactJob` → `Comment`), then ` › <filename>` coloured by extension (§4.1) | artifact size | §5 | archive entries, if it's a multi-file archive; otherwise a leaf |
| **Folder** (inside an archive) | `<name>/` bold in `GitlabTreeDir` (links to `Directory`). When closed, a dimmed note `N files` | sum of the files below it | — | entries |
| **File** (inside an archive) | `<name>`, coloured by extension | file size (uncompressed) | — | — |

- A single-file artifact (reports such as `junit.xml`, `tflint.json`, `results.sarif`, `plan.json`, `build.env`) is a **leaf** directly under its pipeline. `d`, `o` and `y` act on that file.
- The job log (`file_type = trace`) and the archive metadata file are **not** shown.
- Expired artifacts are hidden by default (`setup({ artifacts = { show_expired = false } })`). When shown, they're dimmed with strikethrough and can't be expanded.

### 4.1 Extension colours

Use highlight groups so colourschemes can change them. Defaults (mockup colours):

| Extension(s) | Group → link | Mockup |
|---|---|---|
| `md` | `GitlabFileMarkdown` → `String` | #9ece6a |
| `xml`, `json`, `yml`, `yaml` | `GitlabFileData` → `DiagnosticWarn` | #e0af68 |
| `sarif` | `GitlabFileSecurity` → `DiagnosticError` | #f7768e |
| `gz`, `tgz`, `zip`, `tar` | `GitlabFileArchive` → `Statement` | #bb9af7 |
| `tf`, `hcl` | `GitlabFileCode` → `Special` | #7dcfff |
| `env` | `GitlabFileEnv` → `Type` | #73daca |
| `log`, `sha256`, other | `Normal` / `Comment` | #a9b1d6 |

If `nvim-web-devicons` (or `mini.icons`) is installed, an optional `icons = true` setting adds a file icon before the name. Off by default; the mockup has none.

### Default expansion

On open:
- the **newest pipeline** is expanded,
- the newest pipeline **on the default branch** is expanded too,
- everything else is folded.

Fold state is kept per node id (pipeline id / job id / archive path) while the view is open, and it survives refresh and filtering.

---

## 5. Expires column

| Case | Text | Highlight |
|---|---|---|
| `artifacts_expire_at` is null (keep forever) or the "keep" flag is set | `kept` | `GitlabArtifactKept` → `DiagnosticOk` |
| ≤ 2 days left | `in 1d` / `in 2d` / `today` | `GitlabArtifactExpiring` → `DiagnosticWarn` |
| more | `in Nd` | `Comment` |
| expired | `expired` | `NonText` + strikethrough |

Only artifact rows show it.

---

## 6. Data

| Need | Typical source |
|---|---|
| Recent pipelines with artifacts | the jobs list (`GET /projects/:id/jobs`), or GraphQL. Each job carries `artifacts[] { file_type, filename, size }`, `artifacts_expire_at` and `pipeline { id, ref, status, created_at }`. Group by pipeline. |
| Archive contents | **No API lists files inside an archive.** When an archive is expanded the first time: download it to a cache (`stdpath("cache") .. "/<plugin>/artifacts/<job_id>.zip"`), then list entries (`unzip -Z1` / `zipinfo`, or a small Lua zip reader). Cache by job id; job artifacts don't change. |
| Single file | `GET /projects/:id/jobs/:job_id/artifacts/*artifact_path` streams one file from an archive without downloading the whole zip. Use it for `o` / `d` on files. |

- Load the **last 20 pipelines** that have artifacts. `]p` loads 20 more (same as the pipelines view).
- **Large archives:** if an archive is bigger than `artifacts.confirm_size` (default 50 MB), ask before downloading it to list its contents: `Download 312 MB to browse? y/N`.
- While an archive is being fetched, show a child line `◐ loading…` (`Comment`). On error, show `✗ <message> · R retry` (`DiagnosticError`).
- All network and disk work is async. The cursor never jumps while lines are inserted.
- External tools (`unzip`/`zipinfo`) are optional dependencies: check them at runtime and give a clear message if they're missing. Don't fail on startup.

---

## 7. Interaction

Shared behaviour works as in the other views: filter focus with `/`, cursor rules (only tree rows are selectable), selection kept across re-renders, `R` refresh, `q` / `<Esc>` close.

| Key | On | Action |
|---|---|---|
| `<CR>` / `l` | folder / archive / pipeline | toggle open |
| `<CR>` | file / single-file artifact | same as `o` |
| `h` | any | close the parent node and move the cursor to it |
| `za` / `zo` / `zc` / `zM` / `zR` | any | toggle / open / close / close all / open all (`zR` does **not** download unopened archives; those stay closed) |
| `d` | file | download to `artifacts.download_dir` (default `~/Downloads/`) |
| `d` | artifact | download the whole artifact file (zip or report) |
| `d` | folder | download every file in it (ask if more than 20 files) |
| `d` | pipeline | download all of its artifacts (always ask) |
| `o` | file | open in a read-only scratch buffer named `gitlab://artifacts/<job_id>/<path>`, filetype detected from the name, in a new tab or split (`artifacts.open = "tab" \| "split" \| "vsplit"`). Text files only: binary or > 5 MB → ask, or offer `d` instead |
| `y` | file / artifact | yank the path inside the artifact (`reports/terraform-docs.md`) to `"` and `+` |
| `Y` | file / artifact | yank the GitLab web URL of the file |
| `/` | — | filter (below) |

The footer shows only `[d] Download • [o] Open in buffer • [y] Copy path`. The other keys are documented in `:help` and in a `?` help float, like the other views.

After a download finishes: `vim.notify("Downloaded terraform-docs.md → ~/Downloads/gitlab/infra-automation/4812/reports/")`.

### Filter

- Typed text matches file and folder names, job names, refs and `#<pipeline id>`, case-insensitively.
- Matching nodes stay visible together with **all their ancestors**. The ancestors are opened automatically, but only within archives that are already listed (filtering never triggers downloads). Everything else is hidden.
- Tokens:
  - `ref:<text>`
  - `job:<text>`
  - `type:archive|report`
  - `kept`
  - `expiring` (≤ 2 days)
- Clearing the filter restores the previous fold state.

---

## 8. Highlight groups (new)

All `default = true`:

| Group | Default link |
|---|---|
| `GitlabTreeGuide` | `NonText` |
| `GitlabTreeChevron` | `Function` |
| `GitlabTreeDir` | `Directory` (bold) |
| `GitlabArtifactJob` | `Comment` |
| `GitlabArtifactKept` | `DiagnosticOk` |
| `GitlabArtifactExpiring` | `DiagnosticWarn` |
| `GitlabFile*` | see §4.1 |

Reused: pipeline status icons, `GitlabRefDefault`, `GitlabBranchSource`, `GitlabRefTag`, `GitlabCursorMark`, `GitlabSeparator`, `GitlabColumnHeader`, and the border/title groups.
