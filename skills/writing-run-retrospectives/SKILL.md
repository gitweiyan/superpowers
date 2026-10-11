---
name: writing-run-retrospectives
description: Use when asked to review, explain, or write up what happened in a past operation, agent run, automation test, or task execution (复盘 / retro / postmortem / "这次为什么失败" / "为什么这么慢" / "复盘一下昨天那个测试"), especially when the write-up must be an HTML report with a timestamped event timeline, problem markers, root causes and improvement items.
---

# Writing Run Retrospectives

## Overview

A retrospective is an **evidence document, not a story**. Every timeline entry must point at a source
that can be reopened later (a DB row, a run artifact, a git commit, a session transcript). If you cannot
cite it, either delete the entry or label it `（推断：无直接证据）`.

Deliverable: one **self-contained HTML file** per event, at
`<analyzed-repo>/reports/复盘-<YYYYMMDD>-<事项名>.html`.

## Workflow

1. **Resolve the event** into a time window + keywords, then find **every** run in that window — the
   failed one *and* the rerun that passed. Fail→fix→pass is the object of study; one run alone cannot
   explain the event. Work out the executor: the human, the agent identity/model, and the device.
2. **Collect evidence**:
   `python tools/collect_evidence.py --workspace <repo> --date <YYYY-MM-DD> --keyword <kw> --label <事项名>`
   → `evidence.json` (sessions, timeline, gaps, steps, checks, signals, git, stats.operator_events;
   operator-side events are timeline rows with `origin == "operator"`). Read
   `references/evidence-sources.md` for what each source can and cannot answer.
3. **Build the timeline**: collapse repeated same-source events (`×N`), keep the
   `llm_call / tool / action / agent / span` spine, and **make every silent interval > 15 s its own
   entry** — stalls are where the evidence hides (a 59.8 s gap in a real run was a 30 s adb timeout plus
   a 30 s retry, invisible in every summary).
4. **Mark problems**: entry text is `时间 执行人 动作/对象（标签）`, e.g.
   `2026-10-09 14:14:56 操作人以 Flash profile 触发用例，FlashRunner 初始化即报 API key required（问题暴露）`.
   Tags: `问题引入` / `问题放大` / `问题暴露` / `问题规避`; every problem row renders red.
   A `signal` from the collector is a **hint to verify, not a finding** — read the cited source first
   (a repeated `tap` looked like a defect and turned out to be two legitimate Back navigations).
5. **Analyse root causes** in four classes — environment, agent framework, model, task — each with
   ≥1 evidence citation, a trigger, and ≥1 linked problem. `references/root-cause-taxonomy.md`.
6. **Write improvement items**, ≥1 per root cause, each with a concrete 方案 (file:line, config key,
   command), type, cost, risk, and a **决策 column left as 待决策** — the report proposes, the human
   decides next round. `references/improvement-linkage.md`.
7. **List 沉淀 candidates** (section 6): reusable tools → `tools/`, transferable knowledge →
   `knowledge/` + `INDEX.md`. **Do not write them until the user decides**; the report only names paths.
8. **Verify before delivering**: `python tools/verify_report.py <report.html>`. Every check must pass;
   the footer states the evidence sources and the data gaps. Report what the gate cannot judge.

## Report contract

Copy `assets/report-template.html`; a filled real report is `assets/report-example.html`.
Six sections in order, with clickable `T…→P…→R…→I…` anchors:

| # | Section | Must contain |
|---|---|---|
| 1 | 事项简介 | 执行时间 (start–end, +08:00), 执行人 (**human + agent identity/model + device**), 执行概况, 结果 with numbers, and a one-line conclusion |
| 2 | 执行时间线 | `ID \| 时间 \| 事件 \| 标记 \| 证据`; problem rows red; mitigations green |
| 3 | 问题影响 | per problem: 结果维度 (任务失败/结果不可信/结论不完整/超时) + 过程维度 (冗余步骤/重复操作/无效重试/路径切换/空步/等待空转) + severity |
| 4 | 根因分析 | per cause: class + trigger + **evidence** + linked problems + linked improvements |
| 5 | 改进项 | per item: linked root cause, 方案, 类型, 成本, 风险, 建议, 决策 (交付时 待决策; 决定后回写 已采纳/不采纳 并附可解析引用) |
| 6 | 知识与工具沉淀 | candidates + target paths under this skill directory + status |

See `references/html-conventions.md` for the markup the verifier expects.

## Branch hygiene (landing an improvement)

When a retrospective item turns into a code change, the working tree is part of the evidence: a fix
committed on a sibling branch is not on disk, and `git checkout -b <new> <old-base>` silently rewrites
the tree. Before branching or merging, name the base, verify it by **content**, integrate the other
lines explicitly, and re-check for reversions with
`git diff --stat <branch-with-the-fix> HEAD -- <paths>`. Full procedure, mechanism and the measured
incident: `knowledge/branch-base-regression.md`.

## Red flags - stop and fix

- A timeline entry with no evidence pointer, or a timestamp you did not read from evidence.
- Root causes that are unfalsifiable ("框架不可靠", "模型能力不足") with no line/file/commit behind them.
- An improvement item not linked to a root cause, or one that silently changes code.
- Only the failing run analysed, or only `status` read: in `<analyzed-repo>` traces **every** swallowed failure is
  `status=success`; the truth is in `payload.message`.
- A signal reported as a finding without opening its source.
- "复盘" delivered as prose/markdown when HTML was asked, or HTML that needs the network to render.

## Common mistakes

| Mistake | Fix |
|---|---|
| Trusting the run's own summary (`run_outcome.json`, session status) | Cross-read the log payloads: a `completed` run here had 7 silent degradations, a 60 s stall and an empty archive |
| Reading one data source | DB traces + run directory + git + operator transcript each answer a different question |
| One entry per raw log line | Collapse duplicates, keep the spine, keep every gap |
| Inventing the executor | Name the human, the agent/model, and the device serial |
| Fixing things in the report | The report is a decision document: 决策 stays 待决策 |
