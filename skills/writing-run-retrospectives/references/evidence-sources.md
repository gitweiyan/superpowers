# Evidence sources

Each source answers a different question. Read at least the first three; the fourth is what tells you
*who* did it and is the only place the human/agent split lives.

| # | Source | Answers | Cannot answer |
|---|---|---|---|
| 1 | Run database (`traces/data_engine.db`) | what happened inside each run, to the second | who typed the command, why the task was started |
| 2 | Run directory (`traces/<session>[_RESULT_<time>]/`) | the run's own verdict and artifacts | anything the run did not choose to record |
| 3 | Repo (`git log`, working tree) | what change was introduced before the run | whether the change mattered |
| 4 | Operator transcript (`~/.dsh/sessions/<workspace-slug>/*/session.jsonl.zstd`) | human + agent actions, tool calls, model identity | the device's own behaviour |

## 1. Run database (SQLite, read-only)

```bash
python tools/collect_evidence.py --workspace <repo> --date 2026-10-09 --keyword battery --label <事项名>
```

| Table | Use |
|---|---|
| `sessions` | identity, goal, start/end, status, `device_info` (profile, device_id), video path |
| `steps` | `step_number`, `timestamp`, `action_taken` (JSON), `last_execution_result` |
| `traces` | the event spine: `type` (`log/llm_call/tool/action/agent/span/raw_thinking`), `name`, `timestamp`, `status`, `payload` |
| `images` | screenshots + `ui_tree` per step |
| `video_recordings` | recording window and status |

**The one trap that invalidates whole reports:** in `traces`, a swallowed failure is recorded as
`status='success'`. The reason lives in `payload.message` (and `payload.error`). A run whose every row is
`success` can still have crashed, timed out, or degraded seven times.

## 2. Run directory

| File | Use |
|---|---|
| `run_outcome.json` | `task_status`, `tests` (passed/failed/inconclusive), `environment.switches` |
| `check_ledger.jsonl` | per-item verdicts + `evidence` + `suggestion`; non-`passed` items are findings |
| `check_streams.jsonl` | the checker's own reasoning trail |
| `notes/*.md` | `task_plan.md`, task-specific notes — often the only written goal statement |
| `stdout.log` | timestamped console output (not all runs have it) |
| `recording.mp4` / `recording.json` | video evidence and its time offset |
| `steps.json`, `steps/` | **check before relying on them**: real runs have shipped `steps.json = []` |

If a run directory is missing `run_outcome.json` (a crash before settlement), say so in the footer's
data gaps rather than reconstructing a verdict.

## 3. Repo side

```bash
git -C <repo> log --since=<start-6h> --until=<end+2h> --format='%h|%ad|%an|%s' --date=format:'%Y-%m-%d %H:%M'
git -C <repo> status --porcelain      # uncommitted work is often the actual cause
```

Commits are what the timeline calls `问题引入` when a change is traceable to a run failure. Uncommitted
changes matter too: an edited config with no commit is still a change that was introduced.

## 4. Operator transcript

`~/.dsh/sessions/<workspace-slug>/<session-id>/session.jsonl.zstd` — zstd-compressed JSONL:

| row `type` | fields worth reading |
|---|---|
| `session` | `cwd`, `createdAt`, `agentPreset` (use `cwd` to match a workspace) |
| `request/context` | `provider`, `model` → the agent identity for section 1 |
| `user/message` | the human's request verbatim (and `source.clientTimeZone`) |
| `tool/call` | `name` + `arguments` (`command`, `file_path`, …) — the operator's actions |
| `turn/start`, `step/start` | turn/step boundaries for coarse timing |

Timestamps are epoch **milliseconds**. Subagent sessions appear as their own files: label them as such
instead of attributing their calls to the main operator.

## Timeline construction rules

1. Collapse consecutive events with the same `(name, message)` into one entry with `×N`.
2. Keep every `llm_call / tool / action / agent / span` event: they are the spine.
3. **Emit every silent interval > 15 s (or > 3× the session's median gap) as its own entry.** Stalls are
   where the evidence hides — a real 59.8 s gap was a 30 s adb timeout plus a 30 s retry, invisible in
   every summary of that run.
4. Every entry carries `source` (e.g. `data_engine.db:traces#812`, `git:c9f7266`, `session-…:seq=142`).
   No source, no entry.
5. Convert epochs to local time once, keep the epoch alongside for re-checking.
6. Signals are candidates: open the source before writing a problem. A repeated `tap` looked like a
   defect and was two legitimate Back navigations.
