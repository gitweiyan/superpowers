# Creation log

Skill `writing-run-retrospectives`, v1, created 2026-10-09. This records the RED→GREEN→REFACTOR cycle the
skill was built with, so a later editor knows which failures each rule was written against.

## RED — baseline with no skill

A fresh subagent (no skill loaded, its own context) was given exactly what the user asked for: the
six-section template, the event label `20261009-获取电池信息测试`, and the workspace
`<analyzed-repo>`. It was told to explore read-only and write
`/tmp/retro-baseline/report.html`.

Measured with the same gate the skill ships (`tools/verify_report.py`):

```
RESULT: FAIL (10 problem(s))
  FAIL  utf-8 declared
  FAIL  section s1 mentions '执行时间'
  FAIL  section s6 repeats its title '知识与工具沉淀'
  FAIL  at least 5 timeline entries (found 0)
  FAIL  problems declared (found 0)
  FAIL  root causes declared (found 0)
  FAIL  improvement items declared (found 0)
  FAIL  linkage rules hold
  FAIL  footer lists evidence sources
  FAIL  footer states the data gaps
  note  timeline entries: 0, red-marked: 20
```

Content probes on the same file: no `证据来源` / `数据缺口` anywhere; 20 red-marked elements with no
tag vocabulary behind them; timeline entries exist as prose but carry no per-entry evidence pointer, so
nothing can be re-opened; problems, root causes and improvements are not identified (`P#`/`R#`/`I#` free
text), which makes the "each cause ↔ at least one improvement" rule unverifiable.

**Fair to the baseline:** it did find both runs, the flash/pro profile difference, the
`ChatGoogleGenerativeAI` error and the `inconclusive` count. The RED failures are about **discipline** —
evidence per line, bounded tag semantics, a resolvable T→P→R→I chain, a decision column, stated data gaps —
not about the agent being unable to look things up.

Unfilled at the time of writing: the baseline agent's own summary of the assumptions it had to make
(still running when this log was written; append here when it lands).

### Baseline agent's own report of its limits (verbatim list, condensed)

It delivered 59 timeline entries (08:40–14:32) with 22 red marks and listed **12 conclusions that were
speculation only**: the executor's real name (only the git account `gitweiyan` was visible); the exact
moment the config change landed (boundable only to "before 09:24"); the origin of the Accessibility page
(two candidate paths ruled out, none proven); who switched flash→pro; the mechanism inside the 59.8 s
stall; which code revision 14:14 actually loaded; the model's raw verdict text behind `inconclusive`;
missing operator records before 08:40; whether the weak acceptance criterion was a single-sample
judgement; the purpose of an empty commit; an unattributed cross-day duration difference; and flash's
capability, which could not be evaluated at all.

That list is the honest shape of the gap the skill targets: 12 soft spots in 59 entries, because an
entry without an evidence pointer cannot be settled. The skill's rules (per-entry `source`, "no source →
no entry", gaps as entries, signals verified before promotion) are written against exactly this failure.

### Cross-check value of the baseline

It independently located the checker mechanism behind `inconclusive` (`_normalize_report` matching
`(kind, item_text)` exactly) while the first draft of the skilled report only said "the same item was
registered twice". That claim was verified in source (`<analyzed-repo>/agents/checker/checker.py:462-472`,
including `:449` downgrading evidence-less failures) and promoted into the report's P6, R3 and I7 — so
the baseline run paid for itself twice: as RED evidence and as an adversarial cross-check.


## GREEN — same event, with the skill

The skill was then used for the real deliverable, `reports/复盘-20261009-获取电池信息测试.html`:

```
python tools/verify_report.py reports/复盘-20261009-获取电池信息测试.html
RESULT: PASS — all mechanical checks hold
note  timeline entries: 21, red-marked: 14   (10 problems, 4 root causes, 10 improvements)
```

What the skill added that the baseline lacked, concretely: the 59.8 s silent gap became an entry (and
exposed a 30 s ADB probe timeout); the seven silent degradations inside an otherwise `completed` run
became a problem with its own severity; the repeated `tap` signal was **verified and dismissed** in
writing instead of being reported as a defect; the empty trace archive became `证据缺失`; and every claim
carries a pointer such as `data_engine.db:traces#812` or `check_logger…`-style file references so the
next reader can re-open it.

## REFACTOR — what dogfooding changed

Bugs found by running the gate on the skill's own first output:

1. A `}}` inside `@media print{…}}` counted as an unfilled `{{placeholder}}` → the placeholder scan now
   strips `<style>`/`<script>` and matches `{{…}}`/`TODO`/`TBD`/`xxx` explicitly.
2. Section 4's "linkage rules hold" check counted failures from *other* sections (the failure list was
   global) → each section now measures its own failure delta.
3. Tag semantics were split: `问题引入/问题放大/问题暴露` are defects (red), `问题规避` is a working
   mitigation (green). The first version painted mitigations red too, which hides where the defects are;
   the gate now fails `问题规避` on a red row.
4. The first draft's `P#` rows linked to the section (`#s2`) instead of the entry → timeline rows got
   `id="T#"` anchors and the gate now requires P→T links to resolve to real entries.
5. Adding those anchors was done by an inline script that swallowed the row's first cell: the report
   rendered with an invisible ID column while **every** gate check still passed. The gate now verifies
   that each timeline row's first cell renders its own `T#` chip. Lesson kept in the gate rather than in
   prose: structural mistakes need structural checks.
6. The user then reported the symptom a reader sees first — "ID 列没有内容，表格整体列串了" — on a file
   that had already been repaired, because that bad build had shipped for four minutes. Two consequences
   the skill now carries: (a) the gate also checks that every row of every table has the same number of
   cells as its header (a shifted column is invisible to text-level checks but fatal to the reader), and
   (b) reports carry a **build stamp** (`构建标识：<time> · 时间线 N 条…`) so a stale copy is identifiable
   at a glance instead of triggering another round of debugging. Both checks were negative-tested: delete
   one `T#` chip cell, and drop one `<td>` from a row — each makes the gate fail.

7. The 18:32 retrospective shipped with anchors on its 9 problem rows only: the other 10
   timeline rows rendered their ID chip with no ``id="Tn"``, so a cross-reference to any of
   them would have resolved nowhere. The gate's own summary line (``timeline entries: 9``)
   was the only hint, and it satisfied the "at least 5 entries" rule. The gate now fails a
   row that shows an ID without an anchor, so the count it prints equals the rows that are
   actually addressable. Negative-tested: removing one anchor makes the gate fail.

8. The battery report's decision column was corrupted by a bulk ``str.replace`` without a
   count: every remaining row inherited item I4a's decision text, so seven items that were
   never decided read "已采纳（部分）· …@f7e2844". A second inconsistency went the other way —
   the second retrospective's I1 was landed (``docs/branch-plan.md``, tags, the skill's own
   knowledge file) while its cell still said 待决策. The gate could not see either: it only
   required that a decision keyword appear. It now requires every 已采纳 to cite a commit, a
   tag or a repository path **that resolves**, and it was negative-tested (a bogus sha fails;
   a citation whose only named refs are stale fails). What it still cannot judge is whether a
   decision is *true* — only that it is checkable, which is why the citations are mandatory.

## Known limits of v1

* The gate judges structure, linkage and evidence pointers; it cannot judge whether an analysis is *right*.
  The report still needs a human read (the gate says so in its own output).
* `collect_evidence.py` knows the `<analyzed-repo>`-shaped layout (`traces/data_engine.db`, run directories,
  `~/.dsh/sessions`). Other projects need an adapter or the manual path in
  `references/evidence-sources.md`.
* Section 6 deliberately writes nothing: sinking is a decision the user makes per report.
