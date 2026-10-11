# HTML conventions (what the verifier expects)

One file, no network, no build step. Copy `assets/report-template.html` and keep the structure; the CSS is
already in it, and `assets/report-example.html` is a real filled report to compare against.

## Markup contract

| Element | Requirement |
|---|---|
| `<section id="s1">` … `id="s6"` | six sections, in order; each `<h2>` repeats the section name (事项简介 / 执行时间线 / 问题影响 / 根因分析 / 改进项 / 知识与工具沉淀) |
| §1 | mentions 执行时间 / 执行人 / 执行概况 / 结果 |
| §3 | mentions 结果维度 / 过程维度 |
| §5 | mentions 决策 |
| Timeline row | `<tr id="T7">` (problem rows: `<tr class="problem" id="T5">`), cells: `ID \| 时间 \| 事件 \| 标记 \| 证据` — time and evidence must be non-empty |
| Problem row | `class="problem"` **and** a chip from `问题引入` / `问题放大` / `问题暴露` |
| Mitigation row | chip `问题规避` with `<span class="tag ok">`, **never** `class="problem"` |
| §3 row | `<tr id="P3">`, cites its timeline entries as `<a href="#T7">T7</a>` |
| §4 card | `<div class="card r1" id="R1">`; links problems `<a href="#P1">P1</a>` and improvements `<a href="#I1">I1</a>` |
| §5 row | `<tr id="I1">`, cites `<a href="#R1">R1</a>`, 决策 cell states `待决策` / `已采纳` / `不采纳` (`已采纳` must name a commit, tag or repo path that resolves) |
| Footer | contains `证据来源` and `数据缺口` |

## Rules that are design decisions, not taste

* **Red means defect.** `问题引入/放大/暴露` = red row (red left border + tinted background + red chip).
  Painting a mitigation red hides where the defects are; the verifier fails that case.
* **Every tag sits in parentheses at the end of the event text**, matching the house style:
  `2026-10-09 14:14:56 操作人以 Flash profile 触发用例，FlashRunner 初始化即报 API key required（问题暴露）`.
* **Evidence column carries a re-openable pointer**, not prose: `data_engine.db:traces#812`,
  `check_ledger.jsonl`, `run_outcome.json:environment.switches`, `git:c9f7266`, `session-…:seq=142`.
* **Time format** `MM-DD HH:MM` (or `HH:MM:SS` inside a run) with `(+08:00)` declared once in §1.
* **Self-contained**: inline `<style>`, no `<script src>`, no `<img src="http…">`, `<meta charset="utf-8">`.
* Print-friendly: no interactive-only affordances; `@media print` keeps sections unbroken.

## Authoring checklist before handing over

1. `python tools/verify_report.py <report>` → `RESULT: PASS`.
2. Read §2 aloud: does every red row explain *what* was wrong, and every green row *what* worked?
3. Check that §3 has both axes for every problem, and a severity that matches §4's tone.
4. Check that every §4 card ends with `关联问题` + `关联改进项`, and that §5 covers every `R#`.
5. Confirm the footer names what is **missing** (no `run_outcome.json`, empty archive, no video) so the
   next reader knows the limits of the reconstruction.
