#!/usr/bin/env python3
"""Quality gate for a retrospective report (the skill's step 8).

    python verify_report.py reports/复盘-20261009-获取电池信息测试.html

Checks what can be judged mechanically, so the reviewer only has to judge the
analysis itself:

* the file is self-contained (no CDN/network, inline styles, UTF-8)
* the six required sections exist and section 1 names time / executor / summary / result
* every timeline row carries a time and an evidence pointer
* problem rows are red-marked AND carry a tag from the vocabulary, and no tagged
  row escapes the red marking
* the T -> P -> R -> I chain is complete and resolvable: every problem cites a
  real timeline entry, every root cause cites real problems and at least one
  improvement, every improvement cites a real root cause, and every root cause is
  covered by at least one improvement
* every improvement item states a decision explicitly -- 待决策 while the report
  is an agenda, 已采纳/不采纳 once the human has decided -- and the footer lists
  evidence sources plus data gaps

Exit code 0 = all checks passed.
"""

from __future__ import annotations

import html as html_mod
import re
import subprocess
import sys
from pathlib import Path

#: Tags that mark a defect in the timeline -- these rows must render red.
PROBLEM_TAGS = ("问题引入", "问题放大", "问题暴露")
#: Tags that mark a working mitigation. Green, never red: a good practice is not
#: a problem, and painting it red hides where the defects actually are.
MITIGATION_TAGS = ("问题规避",)
SECTIONS = {
    "s1": ("事项简介", ("执行时间", "执行人", "执行概况", "结果")),
    "s2": ("执行时间线", ()),
    "s3": ("问题影响", ("结果维度", "过程维度")),
    "s4": ("根因分析", ()),
    "s5": ("改进项", ("决策",)),
    "s6": ("知识与工具沉淀", ()),
}
#: A decision of "已采纳" claims work that exists: it has to name something a
#: reader can resolve (a commit, a tag, or a path in the repository).
REF_SHA = re.compile(r"\b([0-9a-f]{7,40})\b")
REF_TAG = re.compile(r"\btag[ :：]+([A-Za-z0-9._/-]+)")
REF_PATH = re.compile(r"((?:tests|docs|packages|mcp_server|scripts|apps|third_party)/[A-Za-z0-9._/-]+)")

PLACEHOLDER_RE = re.compile(r"\{\{[^}]*\}\}|\bTODO\b|\bTBD\b|xxx|填写")


def text(fragment: str) -> str:
    return html_mod.unescape(re.sub(r"<[^>]+>", " ", fragment or "")).strip()


def section_bodies(page: str) -> dict[str, str]:
    bodies = {}
    for sid in SECTIONS:
        match = re.search(rf'<section[^>]*id="{sid}"[^>]*>(.*?)</section>', page, re.DOTALL)
        if match:
            bodies[sid] = match.group(1)
    return bodies


def rows(body: str) -> list[tuple[str, list[str]]]:
    """``[(row attributes, [cell html, ...]), ...]`` for one section."""
    out = []
    for match in re.finditer(r"<tr([^>]*)>(.*?)</tr>", body, re.DOTALL):
        attrs, inner = match.group(1), match.group(2)
        cells = [c for c in re.split(r"<t[dh][^>]*>", inner)[1:]]
        out.append((attrs, cells))
    return out


def _resolves(repo: Path | None, decision: str) -> list[str]:
    """References in a decision cell that actually resolve in ``repo``."""
    found: list[str] = []
    if repo is None:
        return found
    for sha in REF_SHA.findall(decision):
        out = subprocess.run(
            ["git", "-C", str(repo), "cat-file", "-e", f"{sha}^{{commit}}"],
            capture_output=True, text=True,
        )
        if out.returncode == 0:
            found.append(sha)
    for tag in REF_TAG.findall(decision):
        out = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "--verify", f"refs/tags/{tag}"],
            capture_output=True, text=True,
        )
        if out.returncode == 0:
            found.append(f"tag:{tag}")
    for path in REF_PATH.findall(decision):
        if (repo / path).exists():
            found.append(path)
    return found


def ids_in(body: str, prefix: str) -> set[str]:
    return set(re.findall(rf'id="({prefix}\d+)"', body))


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("-")]
    explicit_repo = next((a.split("=", 1)[1] for a in argv[1:] if a.startswith("--repo=")), None)
    if len(args) != 1:
        print(__doc__)
        return 2
    path = Path(args[0])
    if not path.is_file():
        print(f"FAIL: no such report: {path}")
        return 2
    page = path.read_text(encoding="utf-8")
    repo = Path(explicit_repo).expanduser() if explicit_repo else (
        path.resolve().parent.parent if path.resolve().parent.name == "reports" else None
    )
    failures: list[str] = []
    notes: list[str] = []

    def check(ok: bool, message: str) -> None:
        print(("  PASS  " if ok else "  FAIL  ") + message)
        if not ok:
            failures.append(message)

    def mark() -> int:
        """Failure count at a checkpoint, so each section reports only its own."""
        return len(failures)

    print(f"verifying {path} ({len(page)} bytes)")
    if repo is not None:
        print(f"  decisions are resolved against {repo}")

    print("\n[1] self-contained HTML")
    check(page.lstrip().lower().startswith("<!doctype html>"), "starts with <!DOCTYPE html>")
    check("<style>" in page, "inline <style> block present")
    external = re.findall(r'(?:src|href)="(https?://[^"]+)"', page)
    check(not external, f"no external resources (found: {external[:3]})")
    check('<meta charset="utf-8">' in page, "utf-8 declared")

    print("\n[2] required sections")
    bodies = section_bodies(page)
    for sid, (title, required_words) in SECTIONS.items():
        body = bodies.get(sid)
        check(body is not None, f"section {sid} ({title}) present")
        if body is None:
            continue
        check(title in body, f"section {sid} repeats its title {title!r}")
        for word in required_words:
            check(word in text(body), f"section {sid} mentions {word!r}")

    before_tables = mark()
    print("\n[2b] table shape (a shifted column is a defect a reader sees first)")
    for index, block in enumerate(re.findall(r"<table>(.*?)</table>", page, re.DOTALL), 1):
        head = re.search(r"<tr>(.*?)</tr>", block, re.DOTALL)
        expected = len(re.findall(r"<th[ >]", head.group(1))) if head else 0
        for row_html in re.findall(r"<tr([^>]*)>(.*?)</tr>", block, re.DOTALL):
            if "<th" in row_html[1]:
                continue  # the header row itself
            cells = len(re.findall(r"<td[ >]", row_html[1]))
            if cells != expected:
                failures.append(
                    f"table {index}: row with {cells} cells against a {expected}-column header"
                )
                break
    check(mark() == before_tables, "every table row matches its header's column count")

    print("\n[3] timeline rows (time + evidence + red marking)")
    timeline = rows(bodies.get("s2", ""))
    t_ids = ids_in(bodies.get("s2", ""), "T")
    check(len(t_ids) >= 5, f"at least 5 timeline entries (found {len(t_ids)})")
    tagged_but_not_red, red_but_untagged, missing_evidence, mitigation_painted_red = [], [], [], []
    for attrs, cells in timeline:
        chip = re.search(r'<span class="id">(T\d+)</span>', cells[0]) if cells else None
        if 'id="T' not in attrs:
            # A row that shows an ID but carries no anchor is invisible to every
            # cross-reference: it renders fine and P->T links to it resolve nowhere.
            if chip:
                failures.append(f"{chip.group(1)}: row shows an ID but has no anchor")
            continue
        tid = re.search(r'id="(T\d+)"', attrs).group(1)
        cells_text = [text(c) for c in cells]
        if len(cells) < 3:
            failures.append(f"{tid}: fewer than 3 cells")
            continue
        if not cells_text[1]:
            failures.append(f"{tid}: empty time cell")
        # the ID chip must actually render: an anchor on <tr> alone left a real
        # report with an invisible ID column while every other check still passed
        if tid not in text(cells[0]):
            failures.append(f"{tid}: first cell does not render its own ID chip")
        if not cells_text[-1]:
            missing_evidence.append(tid)
        has_problem_tag = any(tag in " ".join(cells_text) for tag in PROBLEM_TAGS)
        has_mitigation = any(tag in " ".join(cells_text) for tag in MITIGATION_TAGS)
        is_red = "problem" in attrs
        if has_problem_tag and not is_red:
            tagged_but_not_red.append(tid)
        if is_red and not has_problem_tag:
            red_but_untagged.append(tid)
        if has_mitigation and is_red:
            mitigation_painted_red.append(tid)
    check(not tagged_but_not_red, f"every problem entry is red-marked (offenders: {tagged_but_not_red})")
    check(not red_but_untagged, f"every red entry carries a problem tag (offenders: {red_but_untagged})")
    check(not mitigation_painted_red,
          f"mitigations are not painted red (offenders: {mitigation_painted_red})")
    check(not missing_evidence, f"every entry cites evidence (offenders: {missing_evidence})")
    notes.append(f"timeline entries: {len(t_ids)}, red-marked: "
                 f"{sum(1 for a, _ in timeline if 'problem' in a)}")

    print("\n[4] linkage T -> P -> R -> I")
    before_linkage = mark()
    problem_rows = [(a, c) for a, c in rows(bodies.get("s3", "")) if 'id="P' in a]
    p_ids = {re.search(r'id="(P\d+)"', a).group(1) for a, _ in problem_rows}
    check(bool(p_ids), f"problems declared (found {len(p_ids)})")
    for attrs, cells in problem_rows:
        pid = re.search(r'id="(P\d+)"', attrs).group(1)
        cited = set(re.findall(r'href="#(T\d+)"', " ".join(cells)))
        if not cited:
            failures.append(f"{pid}: cites no timeline entry")
        unknown = cited - t_ids
        if unknown:
            failures.append(f"{pid}: cites unknown timeline ids {sorted(unknown)}")
    improvement_rows = [(a, c) for a, c in rows(bodies.get("s5", "")) if 'id="I' in a]
    i_ids = {re.search(r'id="(I\d+)"', a).group(1) for a, _ in improvement_rows}
    r_ids = ids_in(bodies.get("s4", ""), "R")
    check(bool(r_ids), f"root causes declared (found {len(r_ids)})")
    check(bool(i_ids), f"improvement items declared (found {len(i_ids)})")

    caused_by: dict[str, set[str]] = {}
    for attrs, cells in improvement_rows:
        iid = re.search(r'id="(I\d+)"', attrs).group(1)
        cited = set(re.findall(r'href="#(R\d+)"', " ".join(cells)))
        caused_by[iid] = cited
        if not cited:
            failures.append(f"{iid}: cites no root cause")
        unknown = cited - r_ids
        if unknown:
            failures.append(f"{iid}: cites unknown root causes {sorted(unknown)}")
        decision = text(cells[-1]) if cells else ""  # the 决策 cell, not the whole row
        if not re.search(r"(待决策|已采纳|不采纳)", decision):
            failures.append(f"{iid}: 决策 column states no decision (待决策/已采纳/不采纳)")
        elif "已采纳" in decision and repo is not None and not _resolves(repo, decision):
            failures.append(
                f"{iid}: 已采纳 but cites no commit, tag or path that resolves in {repo}"
            )
    uncovered = r_ids - {r for cited in caused_by.values() for r in cited}
    check(not uncovered, f"every root cause has >=1 improvement (uncovered: {sorted(uncovered)})")
    check(mark() == before_linkage, "linkage rules hold (see individual failures above)")

    print("\n[5] footer")
    footer = re.search(r"<footer[^>]*>(.*?)</footer>", page, re.DOTALL)
    check(footer is not None, "footer present")
    if footer:
        footer_text = text(footer.group(1))
        check("证据来源" in footer_text, "footer lists evidence sources")
        check("数据缺口" in footer_text, "footer states the data gaps")

    print("\n[6] no unfilled placeholders")
    prose = re.sub(r"<(style|script)[^>]*>.*?</\1>", "", page, flags=re.DOTALL)
    found = PLACEHOLDER_RE.findall(prose)
    check(not found, f"placeholder tokens removed (found: {found[:3]})")

    for note in notes:
        print(f"  note  {note}")
    print()
    if failures:
        print(f"RESULT: FAIL ({len(failures)} problem(s))")
        for item in failures:
            print(f"  - {item}")
        return 1
    print("RESULT: PASS - all mechanical checks hold; the analysis itself still needs a human read")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
