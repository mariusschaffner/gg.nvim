# Pipeline detail — UI spec

Shared foundation: `docs/detail_views_design_spec.md`. Opened by `i` in the pipelines table (also in a merge request's Pipelines tab) and by `gp` in the merge request view. This view has no sidebar and no tabs.

## Header

- **Pill:**

  | Status | Pill |
  |---|---|
  | running, canceling | `◐ Running` |
  | created, pending, preparing, waiting, scheduled | `◷ Pending` |
  | success | `✓ Passed` |
  | failed | `✗ Failed` |
  | canceled, skipped | `⊘ Canceled` |
  | manual | `▶ Manual` |

- **Title:** the merge request's title, else the commit title, else `Pipeline #id`; then `#id`.
- **Right side:** `3:05 elapsed · 4/7 jobs`, or `… total` once finished. The clock is in the status colour.
- **Border:** `pipelines › #id` on the left; `⎇ ref · sha · !mr · user · started … ago` on the right. The bottom border holds the mode hints.
- **Graph** (`detail/pipeline/graph.lua`):
  - **Stage columns:** one per stage with jobs, 28 cells wide, 6 apart. The header shows the name and a summary (`✓ 1:02`, `◐ running`, `manual`).
  - **Job pills:** 3 rows each, holding the icon, the name and the duration or a word.
  - **Pill styles:**
    - manual jobs have a dashed border (`╌` `╎`);
    - the selected job has a thick border (`┏━┓`), in the accent colour while the graph has the keys, and no fill.
  - **Connectors:** from stage to stage at each pill's middle row (`┬ ┴ ├ ┤ └ ┌`). `needs:` edges are not drawn.
  - **Overflow:**
    - stages that don't fit hide behind `‹ n more` / `n more ›`, and the window follows the selection;
    - job rows scroll to keep the selected job visible.

## Job log (the content window)

- **Title:** `◐ job-name`, plus ` ● following ` while following a running job.
- **Footer:** `[F] Follow • [/] Search`.
- **Parsing** (`detail/pipeline/log_model.lua`):
  - CRLF becomes LF. Inside a line, a `\r` keeps only the text after it (terminal redraw).
  - OSC, DCS and non-SGR CSI sequences and control bytes are removed. SGR colours become highlights (`GitlabAnsi*`; 256 and true colour are ignored).
  - Lines without colours are classified: errors red, warnings yellow, `$ cmd` blue, success green.
  - `section_start` / `section_end` give `▾ title · 3s` rows. Finished sections become folds; they start open.
  - Lines with `ERROR` (or classified as errors) get a red background; lines with `WARNING` a yellow one.
- **Opening position:**
  - a running job follows its log, with the cursor on the last line;
  - a failed job opens at its first error;
  - other jobs open at the end.
- **Messages:** `This job hasn't started yet.`, `Loading log…`, `(empty log)`, `Failed to load the job log: …`.

## Modes and keys

| Mode | Keys |
|---|---|
| graph | `h` / `l` stage (skips empty stages, keeps the job index), `j` / `k` job, `<CR>` into the log |
| log | the usual motions and `/` search, `<Esc>` back to the graph |
| both | `F` follow (to the end), `R` reload, `q` back |

- **Default selection:** the first running job, else the first failed job that may not fail, else the first job.
- **Following:** moving the cursor above the last line stops following.

## Live updates (while the view is on top)

| What | When | How |
|---|---|---|
| `gg.pipelines.graph` | every `pipeline_detail_poll_ms` (4000) while the pipeline is active | The selection stays on the same stage and job name, since a retried job has a new id. |
| Header | every second while active | Durations and the elapsed clock are redrawn. |
| Log of the selected running job | every `job_log_poll_ms` (1500) | `gg.jobs.trace` with `offset`: only new bytes, rewritten from the first changed line. A 200 to a range request means the whole log came back, so the view starts over with it. |
| The rest of the log | once, when the job finishes | One last fetch. |

Every timer stops when the view is closed or covered, and resumes (after a refresh) when it is on top again.
