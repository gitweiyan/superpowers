# Tools

Reusable scripts for writing retrospectives. Read-only by default; stdlib only where possible.

| Tool | What it does | Invocation |
|---|---|---|
| `collect_evidence.py` | Collects one event's whole evidence base into `evidence.json`: matching sessions, collapsed timeline (with sources), silent gaps > `--gap-seconds`, steps with repeats flagged, checker items, candidate signals, git window, operator transcript events, agent identity, and the list of sources for the report footer. | `python tools/collect_evidence.py --workspace <repo> --date 2026-10-09 --keyword battery --label 20261009-获取电池信息测试` |
| `verify_report.py` | Quality gate on a filled report: self-contained HTML, six sections, timeline rows have time + evidence, problem rows are red-marked and red rows carry a problem tag, mitigations are not red, the T→P→R→I chain resolves both ways, every improvement states a decision (待决策 / 已采纳 / 不采纳, and 已采纳 must cite a commit, tag or repo path that resolves), footer lists sources and data gaps, no leftover placeholders. | `python tools/verify_report.py reports/复盘-….html` |

## Notes

* `collect_evidence.py` reads the run database read-only (`file:…?mode=ro`); it never writes outside
  `<workspace>/reports/.evidence/`.
* `--context-before-hours/--context-after-hours` widen only the **git and operator** windows; the run
  window stays exact. Cause usually predates the run.
* `--dsh-sessions` defaults to `~/.dsh/sessions`; pass `''` to skip the operator side.
* `zstandard` is optional (falls back to the `zstd` CLI) and only needed for transcripts.
* Signals are candidates: always open the cited source before promoting one to a `P#`.

## Adding a tool

Only when a retrospective step was done by hand and every future one would redo it. Requirements: a
docstring with a copy-pasteable invocation, read-only by default, deterministic output, and a row in this
table.
