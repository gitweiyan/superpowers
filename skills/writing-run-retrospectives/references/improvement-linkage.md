# Improvement linkage and the decision protocol

The report **proposes**; the human **decides next round**. Nothing in a retrospective changes code,
config or process by itself.

## ID scheme

| Prefix | Lives in | Means | Must cite |
|---|---|---|---|
| `T#` | §2 timeline row (`<tr id="T7">`) | one event, with time + evidence | a real source |
| `P#` | §3 row (`<tr id="P3">`) | a defect, on the result + process axes | ≥1 `T#` |
| `R#` | §4 card (`<div class="card r1" id="R1">`) | a root cause in one of four classes | ≥1 `P#` + ≥1 `I#` |
| `I#` | §5 row (`<tr id="I5">`) | an improvement proposal | ≥1 `R#`, plus a 决策 cell that states a decision |
| `K#`/`D#` | §6 row | knowledge / tool to sink into this skill directory | a source `R#`/`P#` |

Rules the verifier enforces: T→P→R→I links all resolve; every `R#` is cited by ≥1 `I#`; every `I#` cites
≥1 `R#`; every `I#`'s 决策 cell states a decision — `待决策`, or `已采纳`/`不采纳` with a commit, tag or
repo path that resolves. Many-to-many is normal — `I10` may serve `R4` and `R2`.

## What makes an improvement item actionable

| Field | Good | Bad |
|---|---|---|
| 方案 | `把 <analyzed-repo>/agents/flash/runner.py:287 的 get_google_llm 换成 provider 感知入口，并保留 Google 分支` | `优化模型接入` |
| 类型 | 代码 / 配置 / 流程 / 工具 / 知识 | `改进` |
| 成本 | 低（<1h，1 文件） / 中（1d，含回归） / 高（跨模块） | 空 |
| 风险 | `摘要器输出格式可能随模型变化，需回归视觉摘要渲染` | 空 |
| 建议 | 建议采纳 / 建议观察 / 不建议（附一句理由） | 空 |
| 决策 | `待决策`（未决定的议程）或 `已采纳/不采纳 · 日期 · 分支@提交`（决定后回写） | 空 |

Order the table by **止损优先**: quick fail-fast and evidence fixes first, structural refactors later.

## Sinking into the skill (section 6)

* **Tool candidate** → `tools/<name>.py` when a step was done by hand that every future retro would redo
  (this is how `collect_evidence.py` and `verify_report.py` got here). Requirements: stdlib-only where
  possible, a docstring with a copy-pasteable invocation, read-only by default.
* **Knowledge candidate** → `knowledge/<topic>.md` when the insight transfers beyond this repo: a
  failure signature, a judgement rule, a gotcha that cost you an hour.
* Each sink entry states the target path and stays `建议沉淀` until the user decides; then add the file,
  add one line to `knowledge/INDEX.md` or `tools/INDEX.md`, and flip the status to `已沉淀`.
* Never sink project-specific fixes here — those belong in the project's own tracker.

## Decision round (what happens after the report)

1. The user marks each `I#` 采纳 / 不采纳 (the report is the agenda). Record the outcome back into
   that row's 决策 cell as `已采纳 · <date> · <branch>@<commit>` (or 不采纳), so the report stays a
   decision record instead of being re-litigated; the gate accepts either an open 待决策 or a recorded
   decision, and fails a row that states neither.
2. Adopted items → implement in the analyzed repo (normal dev workflow, tests included).
3. Adopted 沉淀 items → write `tools/`/`knowledge/` files + index rows, flip the report status.
4. Re-run `tools/verify_report.py` after edits; keep the report as the historical record rather than
   rewriting someone's decisions into it.
