# Stale-target races: a vanished obstacle is *cancelled*, not *completed*

## Symptom

An obstacle-class action (skip a splash ad, dismiss a dialog, close a banner) is judged **failed** and
retried even though the target had already removed itself before the action was dispatched.

Log signature (2026-10-09, session `<session-id>`, step 2, 18:33:13–20):

| Signal | What it says |
|---|---|
| `precondition_xml` failed ×3, then `precondition_pixel` failed ×1 (`conf 0.85, is_present=False`) | the target is genuinely not on screen |
| `Action failed: … Opened execution incident (safety_net/target_disappeared, consecutive=1)` | the validator classified it as a failure and opened an incident for the Operator |
| model's own words: *"the splash ad had already auto-dismissed by the time the tap was dispatched"* | the plan was correct; the screen moved on between capture and dispatch |
| `observation_skew_s` (I5) on the step | how old the screen the action was planned from actually was |

## Mechanism

The plan is derived from a capture; the action is dispatched seconds later. Between the two, the screen
advanced on its own. Validation then spends its whole budget proving the absence of something that no
longer needs doing — 3 XML checks + 1 pixel check + 1 LLM call (≈ 7 s, 2156 prompt tokens) in that run.

## The judgement (corrected 2026-10-10)

| Situation | Wrong answer | Right answer |
|---|---|---|
| Target was present in an earlier capture of this run, is absent now, and the action only clears an obstacle | ① "completed" — claims a success that was never earned; ② "failed + retry" — burns the budget on a moot target | **cancelled / moot (withdrawn)**: record it, close the incident, continue the run |

Why "completed" is not a wording preference:

* the plan grammar has exactly four status characters — `[ ]` pending, `[/]` in progress, `[x]`
  completed, `[!]` blocked — and **"the task terminates only when every top-level milestone is
  `[x]`"** (`<analyzed-repo>/utils/plan_grammar.py`). Marking a target the run never acted on as `[x]`
  fabricates completion *and* feeds the termination decision. It also inflates the success accounting
  a reader takes at face value (`passed` counts, "N steps did the job").
* success has to be evidenced by the target having been acted on. "It disappeared by itself" is
  evidence for *not needing to act*, which is a different fact.
* blocking (`[!]`) is equally wrong: it asserts an unresolved blocker and drags the run toward a
  partial/blocked wrap-up.

The system already has this third answer in it: `retire_check_items`
(`<analyzed-repo>/graph/checkpoints.py`) withdraws check items under user guidance — counted separately as
`retired`, their standing findings popped, their verdicts stopped from driving side effects, and
**never as `passed`**. An obstacle that removed itself is the same shape of fact as an item the user
withdrew: the work is off the table, nobody failed, nothing was achieved.

## Required evidence — all three, or it is a real failure

1. **It was there**: a node for the target in an *earlier* capture of this run (the capture the action
   was planned from).
2. **It is gone now**: this turn's checks say absent (XML and pixel agree).
3. **It is obstacle-class**: skip / dismiss / close. Goal-bearing navigation is not covered — a goal
   target that vanished means the *plan* is wrong, not that the goal is met.

If (1) is missing, the target was never located: that is a genuine failure (bad selector, bad plan) and
must stay one. "Not found twice" is not "disappeared".

## Budget policy

* **Obstacle-class**: 1× XML + 1× pixel, then judge. One check each is enough to establish an absence;
  the extra passes above bought nothing.
* **Goal-bearing navigation**: keep the normal budget.
* Whatever the budget, keep the "was present → is absent" lines as the evidence for the cancellation,
  so the decision can be re-derived later instead of trusted.

## Anti-patterns

| Anti-pattern | Why it is wrong |
|---|---|
| Marking the obstacle subgoal `[x]` | Fabricates completion, can end the task early, corrupts `passed` accounting |
| Marking it `[!]` (blocked) | Asserts an unresolved blocker that no longer exists |
| Retrying into `failed` | Spends budget and an LLM call on a moot target, opens a misleading incident |
| Widening it to "any failed precondition = target disappeared" | Erases real locator/selector failures — the case where the run genuinely needs help |

## Related

* **I5 / `observation_skew_s`** is the measurable half of this race: it turns "the screen may have moved
  on" into a number on the step record, and is the evidence a cancellation judgement should cite.
* **I4** is the item that changes the judgement and the budget; this note is the identification knowledge
  behind it. Implement I4 as *cancel*, never as *complete* — the wording decides which accounting the
  run reports.
* **`retired`** in `run_outcome.tests` (`<analyzed-repo>/graph/checkpoints.py`) is the existing precedent for a
  third state that is neither passed nor failed.
