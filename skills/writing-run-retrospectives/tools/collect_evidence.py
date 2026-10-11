#!/usr/bin/env python3
"""Collect the evidence a retrospective needs: one workspace, one time window.

Standard library only. ``zstandard`` is optional and used only to read the
operator-side agent transcripts under ``~/.dsh/sessions/``.

    python collect_evidence.py --workspace /repo --date 2026-10-09 --keyword 电池
    python collect_evidence.py --workspace /repo --session <session-id-1> --session <session-id-2>
    python collect_evidence.py --workspace /repo --date 2026-10-09 --out evidence.json

What it emits (JSON):

* ``sessions``   - identity, goal, profile, status, device, run directory, run_outcome
* ``timeline``   - every event of every run, collapsed duplicates, each with a ``source``; the
                   operator/agent side (tool calls read from the session transcript) appears here
                   too, as events with ``origin == "operator"``
* ``gaps``       - silent intervals inside a run (> ``--gap-seconds``), the richest signal
* ``steps``      - device actions per step, with repeats flagged
* ``checks``     - checker ledger items, non-passed ones first
* ``signals``    - candidate problems with their evidence pointer (never a verdict)
* ``git``        - commits and uncommitted changes in the window (what was introduced)
* ``stats``      - counts, including ``stats["operator_events"]`` (how many operator-side events
                   ended up in ``timeline``)
* ``sources``    - every file and table that was read, for the report footer

A signal is a *hint to verify*, not a finding: read the cited source before the
report claims anything.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

LOCAL_TZ = datetime.now().astimezone().tzinfo

#: Message shapes that have meant something in real runs. Each hit becomes a
#: candidate problem with the line that produced it.
SIGNAL_PATTERNS: list[tuple[str, str]] = [
    ("failed", r"\bfailed\b|\bFAIL\b|会话结束.*failed"),
    ("error", r"\bError\b|Traceback|Exception|validation error"),
    ("timeout", r"timed out|timeout after"),
    ("denied", r"Permission Denial|permission denied|SecurityException"),
    ("unavailable", r"unavailable|not answering|unreachable"),
    ("fallback", r"falling back|serving from|fallback"),
    ("retry", r"retrying|retry in|attempt \d"),
    ("unknown-command", r"Unknown command"),
    ("inconclusive", r"inconclusive|no verdict"),
    ("missing-artifact", r"did not report|Found 0 images|Found 0 steps"),
]

ACTIONLESS = ("none", "null", "")


def iso(epoch: float | int | None) -> str | None:
    if epoch is None:
        return None
    try:
        return datetime.fromtimestamp(float(epoch), LOCAL_TZ).isoformat(timespec="seconds")
    except (OverflowError, OSError, ValueError):
        return None


def read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def read_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        pass
    return rows


def run(cmd: list[str], cwd: Path | None = None) -> str:
    try:
        out = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=60)
        return out.stdout if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


# --------------------------------------------------------------------------- #
# Run data (the DB an <analyzed-repo>-style workspace keeps under traces/)
# --------------------------------------------------------------------------- #


def pick_db(workspace: Path, explicit: str | None) -> Path | None:
    for cand in (explicit, workspace / "traces" / "data_engine.db", workspace / "data_engine.db"):
        if cand and Path(cand).is_file():
            return Path(cand)
    return None


def session_rows(db: Path, args) -> list[sqlite3.Row]:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    rows = list(con.execute("select * from sessions order by start_time"))
    con.close()
    picked = []
    for row in rows:
        sid = row["session_id"]
        if args.session:
            if any(sid.startswith(s) for s in args.session):
                picked.append(row)
            continue
        started = iso(row["start_time"]) or ""
        if args.date and not started.startswith(args.date):
            continue
        goal = str(row["initial_goal"] or "")
        if args.keyword and not any(k.lower() in goal.lower() for k in args.keyword):
            continue
        picked.append(row)
    return picked


def timeline_from_db(db: Path, session_id: str) -> list[dict]:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = list(
        con.execute(
            "select rowid, timestamp, type, name, status, payload from traces "
            "where session_id = ? order by timestamp",
            (session_id,),
        )
    )
    con.close()
    events: list[dict] = []
    for rowid, ts, kind, name, status, payload in rows:
        try:
            data = json.loads(payload) if payload else {}
        except ValueError:
            data = {"raw": str(payload)[:200]}
        text = data.get("message") or data.get("error") or ""
        if not text:
            interesting = {k: v for k, v in data.items() if k not in ("session_id", "step_id")}
            text = json.dumps(interesting, ensure_ascii=False)[:200]
        events.append(
            {
                "iso": iso(ts),
                "epoch": ts,
                "session_id": session_id,
                "origin": "run",
                "type": kind,
                "name": name,
                "status": status,
                "text": " ".join(str(text).split())[:400],
                "source": f"{db.name}:traces#{rowid}",
                "count": 1,
            }
        )
    return events


def steps_from_db(db: Path, session_id: str) -> list[dict]:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = list(
        con.execute(
            "select step_number, timestamp, action_taken, last_execution_result, summary "
            "from steps where session_id = ? order by step_number",
            (session_id,),
        )
    )
    con.close()
    steps: list[dict] = []
    for number, ts, action, result, summary in rows:
        steps.append(
            {
                "step": number,
                "iso": iso(ts),
                "epoch": ts,
                "action": summarize_action(action),
                "result": " ".join(str(result or "").split())[:200],
                "summary": summary,
                "source": f"{db.name}:steps#session={session_id[:8]}/step={number}",
            }
        )
    return steps


def summarize_action(raw) -> str:
    try:
        parsed = json.loads(raw) if isinstance(raw, str) else raw
    except ValueError:
        return " ".join(str(raw or "").split())[:160]
    if not isinstance(parsed, list):
        parsed = [parsed]
    parts: list[str] = []
    for item in parsed:
        if not isinstance(item, dict):
            parts.append(str(item)[:60])
            continue
        name = item.get("action") or item.get("name") or "?"
        detail = item.get("coordinates") or item.get("text") or item.get("package") or ""
        if isinstance(detail, list):
            detail = f"({','.join(str(x) for x in detail)})"
        parts.append(f"{name}{detail}" if detail else str(name))
    return "; ".join(parts)[:200] or "(none)"


def collapse(events: list[dict]) -> list[dict]:
    """Fold consecutive identical events into one entry with a count."""
    out: list[dict] = []
    for event in events:
        if (
            out
            and out[-1]["name"] == event["name"]
            and out[-1]["text"] == event["text"]
            and out[-1]["session_id"] == event["session_id"]
        ):
            out[-1]["count"] += 1
            continue
        out.append(event)
    return out


def find_gaps(events: list[dict], threshold: float) -> list[dict]:
    gaps: list[dict] = []
    previous = None
    for event in events:
        if previous is not None and event["epoch"] is not None and previous["epoch"] is not None:
            delta = float(event["epoch"]) - float(previous["epoch"])
            if delta >= threshold:
                gaps.append(
                    {
                        "session_id": event["session_id"],
                        "from_iso": previous["iso"],
                        "to_iso": event["iso"],
                        "seconds": round(delta, 1),
                        "before": f"{previous['name']}: {previous['text'][:120]}",
                        "after": f"{event['name']}: {event['text'][:120]}",
                        "source": previous["source"],
                    }
                )
        previous = event
    return gaps


def find_run_dir(workspace: Path, session_id: str) -> Path | None:
    traces = workspace / "traces"
    if not traces.is_dir():
        return None
    short = session_id.split("-")[0]
    cands = [p for p in traces.glob(f"*{short}*") if p.is_dir()]
    # The finished directory carries the result and the end time; prefer it.
    cands.sort(key=lambda p: ("_FAIL" in p.name or "_PASS" in p.name, p.stat().st_mtime))
    return cands[-1] if cands else None


def run_artifacts(run_dir: Path | None) -> dict:
    if run_dir is None:
        return {}
    files = sorted(p.name for p in run_dir.iterdir()) if run_dir.is_dir() else []
    notes = sorted(p.name for p in (run_dir / "notes").glob("*")) if (run_dir / "notes").is_dir() else []
    return {
        "dir": str(run_dir),
        "files": files,
        "notes": notes,
        "run_outcome": read_json(run_dir / "run_outcome.json"),
        "check_ledger": read_jsonl(run_dir / "check_ledger.jsonl"),
        "check_streams": read_jsonl(run_dir / "check_streams.jsonl"),
        "stdout_log": (run_dir / "stdout.log").is_file(),
    }


def note_texts(run_dir: Path | None, limit: int = 400) -> dict:
    if run_dir is None or not (run_dir / "notes").is_dir():
        return {}
    out = {}
    for path in sorted((run_dir / "notes").glob("*.md")):
        try:
            out[path.name] = path.read_text(encoding="utf-8")[:limit]
        except OSError:
            continue
    return out


# --------------------------------------------------------------------------- #
# Repo side (what was introduced) and operator side (who did what)
# --------------------------------------------------------------------------- #


def git_window(workspace: Path, start: datetime, end: datetime) -> dict:
    fmt = "%h|%ad|%an|%s"
    log = run(
        [
            "git", "-C", str(workspace), "log",
            f"--since={start.isoformat()}", f"--until={end.isoformat()}",
            f"--date=format:%Y-%m-%d %H:%M", f"--format={fmt}",
        ]
    )
    commits = []
    for line in log.splitlines():
        bits = line.split("|", 3)
        if len(bits) == 4:
            commits.append({"commit": bits[0], "when": bits[1], "author": bits[2], "subject": bits[3]})
    status = run(["git", "-C", str(workspace), "status", "--porcelain"]).splitlines()
    return {"commits": commits, "dirty_files": [s for s in status if s.strip()]}


def transcript_paths(root: Path, workspace: Path) -> list[Path]:
    found: list[Path] = []
    if not root.is_dir():
        return found
    for project in root.iterdir():
        if not project.is_dir():
            continue
        for session in project.iterdir():
            path = session / "session.jsonl.zstd"
            if path.is_file():
                found.append(path)
    return found


def read_transcript(path: Path) -> list[dict]:
    """Yield the transcript's JSON lines (zstd-compressed jsonl)."""
    try:
        import zstandard  # type: ignore
    except ImportError:
        text = run(["zstd", "-dc", str(path)])
    else:
        try:
            with open(path, "rb") as fh:
                text = zstandard.ZstdDecompressor().stream_reader(fh).read().decode("utf-8", "replace")
        except Exception:  # pylint: disable=broad-exception-caught
            text = ""
    rows: list[dict] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return rows


def operator_events(root: Path, workspace: Path, start: float, end: float) -> tuple[list[dict], dict]:
    events: list[dict] = []
    identity: dict = {}
    target = str(workspace.resolve())
    for path in transcript_paths(root, workspace):
        rows = read_transcript(path)
        if not rows:
            continue
        header = next((r for r in rows if r.get("type") == "session"), {})
        if str(header.get("cwd", "")).rstrip("/") != target:
            continue
        for row in rows:
            kind = row.get("type")
            when = row.get("time")
            if kind == "request/context":
                data = row.get("data", {})
                identity = {"provider": data.get("provider"), "model": data.get("model"),
                            "source": str(path)}
            if kind == "user/message":
                data = row.get("data", {})
                texts = [c.get("text", "") for c in data.get("content", []) if isinstance(c, dict)]
                if texts and when and start * 1000 <= when <= end * 1000:
                    events.append({
                        "iso": iso(when / 1000), "epoch": when / 1000, "origin": "operator",
                        "type": "user-message", "name": "user", "status": "",
                        "text": " ".join(" ".join(texts).split())[:300],
                        "source": f"{path.name}:seq={row.get('seq')}", "count": 1,
                    })
                continue
            if kind != "tool/call" or not when or not (start * 1000 <= when <= end * 1000):
                continue
            raw = row.get("data", {}).get("arguments") or "{}"
            try:
                args = json.loads(raw) if isinstance(raw, str) else raw
            except ValueError:
                args = {"raw": str(raw)[:120]}
            summary = args.get("command") or args.get("file_path") or args.get("description") or ""
            if not summary:
                summary = json.dumps(args, ensure_ascii=False)
            events.append({
                "iso": iso(when / 1000), "epoch": when / 1000, "origin": "operator",
                "type": "tool-call", "name": row.get("data", {}).get("name", "tool"), "status": "",
                "text": " ".join(str(summary).split())[:300],
                "source": f"{path.parent.name}:seq={row.get('seq')}", "count": 1,
            })
    events.sort(key=lambda e: e["epoch"] or 0)
    return events, identity


# --------------------------------------------------------------------------- #
# Signals
# --------------------------------------------------------------------------- #


def signals_from(events: list[dict], gaps: list[dict], steps: list[dict], checks: list[dict],
                 artifacts: dict) -> list[dict]:
    signals: list[dict] = []
    for event in events:
        for kind, pattern in SIGNAL_PATTERNS:
            if re.search(pattern, event["text"] or "", re.IGNORECASE):
                signals.append({"kind": kind, "iso": event["iso"], "session_id": event["session_id"],
                                "text": event["text"][:220], "source": event["source"]})
                break
        if event.get("status") and str(event["status"]).lower() not in ("success", "ok", ""):
            signals.append({"kind": "non-success-status", "iso": event["iso"],
                            "session_id": event["session_id"],
                            "text": f"[{event['status']}] {event['text'][:200]}",
                            "source": event["source"]})
    for gap in gaps:
        signals.append({"kind": "silent-gap", "iso": gap["from_iso"], "session_id": gap["session_id"],
                        "text": f"{gap['seconds']}s with no event: {gap['before'][:100]} -> {gap['after'][:100]}",
                        "source": gap["source"]})
    previous = None
    for step in steps:
        if previous and step["action"] == previous["action"] and step["action"].strip().lower() not in ACTIONLESS:
            signals.append({"kind": "repeated-action", "iso": step["iso"], "session_id": "",
                            "text": f"step {previous['step']} and {step['step']} both did {step['action']}",
                            "source": step["source"]})
        if str(step["action"]).strip().lower() in ACTIONLESS:
            signals.append({"kind": "empty-step", "iso": step["iso"], "session_id": "",
                            "text": f"step {step['step']} recorded no action",
                            "source": step["source"]})
        previous = step
    for item in checks:
        status = str(item.get("status", "")).lower()
        if status and status != "passed":
            signals.append({"kind": f"check-{status}", "iso": iso(item.get("ts")), "session_id": "",
                            "text": f"{item.get('item_text', '')[:160]} | evidence: {str(item.get('evidence'))[:120]}",
                            "source": "check_ledger.jsonl"})
    outcome = artifacts.get("run_outcome") or {}
    for switch in (outcome.get("environment") or {}).get("switches", []) or []:
        signals.append({"kind": "backend-switch", "iso": iso(switch.get("time")), "session_id": "",
                        "text": f"backend={switch.get('backend')} reason={switch.get('reason')}",
                        "source": "run_outcome.json:environment.switches"})
    return signals


# --------------------------------------------------------------------------- #


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Collect retrospective evidence (read-only).")
    parser.add_argument("--workspace", required=True, help="repository that ran the event")
    parser.add_argument("--date", help="local date of the event, YYYY-MM-DD")
    parser.add_argument("--keyword", action="append", default=[], help="match against the run goal")
    parser.add_argument("--session", action="append", default=[], help="session id or prefix")
    parser.add_argument("--db", help="path to data_engine.db (default: <workspace>/traces/)")
    parser.add_argument("--label", help="event label used to name the report")
    parser.add_argument("--gap-seconds", type=float, default=15.0)
    #: The runs are the object of study; the code that was introduced before them
    #: and the operator's own actions are what usually *caused* it, so the git and
    #: transcript windows are wider than the run window on purpose.
    parser.add_argument("--context-before-hours", type=float, default=12.0)
    parser.add_argument("--context-after-hours", type=float, default=6.0)
    parser.add_argument("--dsh-sessions", default=str(Path.home() / ".dsh" / "sessions"),
                        help="operator transcript root ('' to skip)")
    parser.add_argument("--out", help="evidence.json destination")
    args = parser.parse_args(argv)

    workspace = Path(args.workspace).expanduser().resolve()
    if not workspace.is_dir():
        print(f"workspace not found: {workspace}", file=sys.stderr)
        return 2
    db = pick_db(workspace, args.db)
    label = args.label or "-".join(
        [p for p in [args.date or "", *(args.keyword or []), *(args.session or [])] if p]
    ) or "event"

    sources: list[dict] = []
    sessions: list[dict] = []
    timeline: list[dict] = []
    all_steps: list[dict] = []
    all_checks: list[dict] = []
    all_gaps: list[dict] = []

    rows = session_rows(db, args) if db else []
    if db:
        sources.append({"kind": "sqlite", "path": str(db),
                        "what": "sessions, steps, traces (type/name/status/payload.message)"})
    for row in rows:
        sid = row["session_id"]
        run_dir = find_run_dir(workspace, sid)
        artifacts = run_artifacts(run_dir)
        device = json.loads(row["device_info"]) if row["device_info"] and str(row["device_info"]).startswith("{") else {}
        sessions.append({
            "session_id": sid, "goal": row["initial_goal"], "status": row["status"],
            "start_iso": iso(row["start_time"]), "end_iso": iso(row["end_time"]),
            "start_epoch": row["start_time"], "end_epoch": row["end_time"],
            "profile": device.get("profile"), "device_id": device.get("device_id"),
            "device_model": device.get("device_model"), "run_dir": artifacts.get("dir"),
            "run_outcome": artifacts.get("run_outcome"), "artifacts": artifacts.get("files", []),
            "notes": note_texts(run_dir), "video": row["video_filepath"],
        })
        events = timeline_from_db(db, sid)
        all_steps.extend(steps_from_db(db, sid))
        all_checks.extend(artifacts.get("check_ledger") or [])
        collapsed = collapse(events)
        all_gaps.extend(find_gaps(collapsed, args.gap_seconds))
        timeline.extend(collapsed)
        for key in ("run_outcome.json", "check_ledger.jsonl", "check_streams.jsonl"):
            if artifacts.get("dir"):
                sources.append({"kind": "file", "path": os.path.join(artifacts["dir"], key),
                                "what": "run artifact"})

    if not rows:
        print(f"warning: no session matched (db={db}, date={args.date}, "
              f"keyword={args.keyword}, session={args.session})", file=sys.stderr)

    times = [s["start_epoch"] for s in sessions if s["start_epoch"]] + \
            [s["end_epoch"] for s in sessions if s["end_epoch"]]
    start = min(times) if times else (datetime.now().timestamp() - 3600)
    end = max(times) if times else datetime.now().timestamp()
    window_start = datetime.fromtimestamp(start, LOCAL_TZ) - timedelta(hours=args.context_before_hours)
    window_end = datetime.fromtimestamp(end, LOCAL_TZ) + timedelta(hours=args.context_after_hours)

    git = git_window(workspace, window_start, window_end)
    if git["commits"] or git["dirty_files"]:
        sources.append({"kind": "git", "path": str(workspace / ".git"),
                        "what": f"commits {window_start.isoformat(timespec='minutes')} .. "
                                f"{window_end.isoformat(timespec='minutes')}, plus working tree"})
    for entry in git["commits"]:
        epoch = None
        try:
            epoch = datetime.strptime(entry["when"], "%Y-%m-%d %H:%M").replace(tzinfo=LOCAL_TZ).timestamp()
        except ValueError:
            pass
        timeline.append({
            "iso": iso(epoch), "epoch": epoch, "session_id": "", "origin": "repo",
            "type": "commit", "name": "git", "status": "",
            "text": f"{entry['commit']} {entry['subject']} ({entry['author']})",
            "source": f"git:{entry['commit']}", "count": 1, "when": entry["when"],
        })

    operator: list[dict] = []
    identity: dict = {}
    if args.dsh_sessions:
        operator, identity = operator_events(
            Path(args.dsh_sessions).expanduser(), workspace, start - args.context_before_hours * 3600,
            end + args.context_after_hours * 3600,
        )
        if operator:
            sources.append({"kind": "transcript", "path": str(Path(args.dsh_sessions).expanduser()),
                            "what": "operator/agent tool calls (session.jsonl.zstd)"})
            timeline.extend(operator)

    timeline.sort(key=lambda e: (e["epoch"] if e["epoch"] is not None else float("inf")))
    signals = signals_from(
        [e for e in timeline if e["origin"] == "run"], all_gaps, all_steps, all_checks,
        {"run_outcome": next((s["run_outcome"] for s in sessions if s.get("run_outcome")), {})},
    )

    evidence = {
        "generated_at": datetime.now(LOCAL_TZ).isoformat(timespec="seconds"),
        "event": {"label": label, "date": args.date, "keywords": args.keyword,
                  "sessions": [s["session_id"] for s in sessions],
                  "window": {"from": iso(start), "to": iso(end)}},
        "agent_identity": identity,
        "sessions": sessions,
        "timeline": timeline,
        "gaps": all_gaps,
        "steps": all_steps,
        "checks": all_checks,
        "signals": signals,
        "git": git,
        "sources": sources,
        "stats": {
            "sessions": len(sessions),
            "timeline_entries": len(timeline),
            "run_events_raw": len([e for e in timeline if e["origin"] == "run"]),
            "gaps": len(all_gaps),
            "signals": len(signals),
            "commits": len(git["commits"]),
            "operator_events": len([e for e in timeline if e["origin"] == "operator"]),
        },
    }

    out = Path(args.out).expanduser() if args.out else \
        workspace / "reports" / ".evidence" / f"evidence-{label}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"evidence: {out}")
    print(json.dumps(evidence["stats"], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
