# Root cause taxonomy

Four classes. Every cause needs: a **class**, a **trigger** (what made it fire), **evidence** (file:line,
DB row, log line, commit), ≥1 **linked problem** and ≥1 **linked improvement**.

Classify by asking "what would have to change for this to stop happening?" — that is where the fix lands.

## 环境原因 (environment)

Probe: was the platform, device, network, ADB, ROM or a permission unstable or unsupported?

Signals in evidence: `timed out`, `ADB command failed`, `Unknown command`, `Permission Denial`,
`offline`, reconnect/transport-id changes, wake-lock / stay-awake refusals, emulator-vs-device differences.

Example (real): one `adb shell dumpsys package` call hung 30 s while a similar call four minutes earlier
took 4 s; the client read that as "helper unavailable", fell back to UIAutomator2 and retried 30 s later.
Root cause = transient ADB/device stall; the *fallback policy* turned it into a 60 s stall and a backend
flip-flop. Improvements: short timeouts with a retry budget; treat one slow probe as slow, not as absent.

## Agent 框架原因 (agent framework)

Probe: did the orchestration or its gates mis-sequence steps, lose state, double-register work, swallow
errors, or emit artifacts that cannot be audited?

Signals: gate/bounce messages (`Plan ledger gate: bouncing action`), "feeding back to LLM" retries, the
same check item registered twice with different prefixes, `inconclusive`/`no verdict produced`,
`Found 0 images/steps` on archive, steps recorded with no action, backend switched mid-run, retries
without a budget.

Example (real): the final checker registered the same item as `[verify] …` and as bare text; the first
passed, the second produced `no verdict produced for this item` → `inconclusive=1` in the run's own
verdict. The task was fine; the report was polluted by a registration bug.

## 模型原因 (model)

Probe: was the provider/model wiring wrong, the model unavailable, or the reasoning itself off
(protocol violations, wrong coordinates, wrong tool arguments, loops)?

Signals: provider validation errors (`API key required`, `Unknown LLM provider`), `get_google_llm`-style
hardcoding contradicting the configured provider, repeated identical actions, corrections after a failed
attempt ("Some action calls failed validation. Feeding back to LLM."), thinking that contradicts the
screen.

Example (real): the workspace was configured for a non-Google endpoint while the flash path built a
Google client with the configured model name — the run died in 12 s; in Pro the same wiring silently
disabled memory compression (4×) and visual summarisation (3×) while the run "completed".

## 任务原因 (task)

Probe: was the request ambiguous, the acceptance criterion undefined, the precondition unstated, or the
device left in an unexpected state by the previous run?

Signals: the planner inventing an acceptance check, the first plan item being "navigate back from …",
extra LLM calls spent defining the goal, a run that "passes" without demonstrating the thing asked for.

Example (real): "Open Settings and check the Battery level" did not state a start screen nor what
"check" means; the previous debugging session had left the device on the Accessibility page, so the plan
opened with two Back navigations and the planner had to invent the acceptance item that later became the
duplicated check.

## Anti-patterns

| Don't write | Write instead |
|---|---|
| "agent 框架不可靠" | which gate/tool, at what timestamp, with which log line, causing which problem |
| "模型能力不足" | the exact request/response pair or the validation error, plus the wrong output |
| "环境问题" | which command timed out, for how long, and what the fallback then did |
| A cause with no improvement | a cause you cannot act on is an observation — move it to the timeline, not to R# |
| One cause per problem, one problem per cause | many-to-many is normal: link them explicitly both ways |
