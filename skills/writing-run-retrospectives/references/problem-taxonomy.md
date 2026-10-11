# Problem taxonomy

A problem is a **defect of the operation**, described on two axes. Both axes are mandatory: the result
axis says what the user got, the process axis says what it cost.

Severity: **高** = task failed / result untrustworthy or the run's own verdict is wrong; **中** = extra
work, extra tokens, or a verdict that misleads; **低** = cosmetic, hygiene, or a cost you can live with.

## 结果维度 (what the user got)

| Value | Meaning |
|---|---|
| 任务失败 | the run produced no result at all |
| 部分成功 | the goal was reached but sub-goals or checks remain open |
| 结果不可信 | the answer cannot be trusted (silent degradation, contradictory evidence) |
| 结论不完整 | the verdict is missing items (`inconclusive`, `no verdict produced`) |
| 超时 | the run or a phase exceeded its budget |
| 无直接影响 | the defect was absorbed; keep it only if it can bite later |

## 过程维度 (what it cost)

| Value | Meaning | Typical evidence |
|---|---|---|
| 冗余步骤 | work that the final outcome did not need (install + record + wait, then crash) | ordering in the timeline: heavy setup before a step that cannot succeed |
| 重复操作 | the same action issued twice **without** a state change justifying it | two identical actions with no screen change between them |
| 无效重试 | an attempt that could not succeed, or a retry with no budget | bounce/gate messages, retry logs |
| 等待空转 | time burned without progress | silent gaps, fixed sleeps, `did not report … within Ns` |
| 路径切换 | the execution path changed mid-run | backend/engine switches, fallback + recovery |
| 空步 | a step recorded with no action | `action=None`, `LLM stopped without calling any tool` |
| 证据缺失 | the operation left no auditable artifact | empty `steps.json`, `Found 0 images/steps`, missing `run_outcome.json` |

## Signals are hints, not findings

The collector emits `signals` (repeated actions, silent gaps, non-success checks, error-shaped log lines,
backend switches, empty steps). Each is a **place to look**, carrying a `source`. Before it becomes a P#:

1. Open the cited source.
2. Decide whether the behaviour was correct given the state at that moment.
3. If it was correct, write it into the report's `非问题项（已核实排除）` note — that record is what stops
   the next reader from re-litigating it.

Worked example: `repeated-action: step 1 and 2 both did tap(72,143)` looked like a duplicate tap. The
raw thinking at 14:32:14 read *"my previous back tap moved me out of Accessibility into this sub-menu"*,
and the screen changed between the two steps. Two Back navigations on two nested screens: **not a
problem**, but the *reason* the run started two levels deep (a previous session left the device on the
Accessibility page) became P8 — 冗余步骤.

## Mapping to the timeline

Every P# cites ≥1 timeline entry (`<a href="#T7">T7</a>`). If a problem cannot be pinned to a moment, it
is a standing condition: put it under a root cause as a trigger, or drop it.
