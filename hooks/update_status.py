#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
update_status.py — Claude Code hook → update per-session status file

Called from ~/.claude/settings.json hooks. Usage:
    update_status.py <state>
    # state: running | pending | done

Claude Code passes the hook payload as JSON on stdin. We extract session_id,
transcript_path, cwd, look up the first user message from the transcript, and
merge our session entry into ~/.claude-menubar/status.json.
"""
import fcntl
import json
import os
import sys
import time
from pathlib import Path

DIR = Path.home() / ".claude-menubar"
FILE = DIR / "status.json"
LOCK = DIR / "status.lock"
SESSION_TTL = 3600  # prune sessions untouched for > 1 hour
LABEL_MAX = 40


def read_payload():
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw.strip() else {}
    except (json.JSONDecodeError, OSError):
        return {}


def first_user_text(transcript_path: str) -> str:
    if not transcript_path or not os.path.exists(transcript_path):
        return ""
    try:
        with open(transcript_path, "r", encoding="utf-8") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if d.get("type") != "user":
                    continue
                msg = d.get("message")
                if not isinstance(msg, dict) or msg.get("role") != "user":
                    continue
                content = msg.get("content")
                text = ""
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    for part in content:
                        if isinstance(part, dict) and part.get("type") == "text":
                            text = part.get("text", "")
                            break
                text = text.strip()
                if not text:
                    continue
                # Skip tags / commands / tool-call brackets / file refs
                if text.startswith(("<", "/", "[", "@")):
                    continue
                # Skip skill / system injected openers
                lowered = text.lower()
                if lowered.startswith(("base directory for", "caveat:", "system:")):
                    continue
                if len(text) < 3:
                    continue
                return text
    except OSError:
        return ""
    return ""


def truncate(s: str, n: int = LABEL_MAX) -> str:
    s = " ".join(s.split())  # collapse whitespace
    return s if len(s) <= n else s[: n - 1] + "…"


def load_state():
    if not FILE.exists():
        return {"sessions": {}}
    try:
        with open(FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if "sessions" not in data:
            data = {"sessions": {}}
        return data
    except (json.JSONDecodeError, OSError):
        return {"sessions": {}}


def save_state(data):
    tmp = FILE.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, FILE)


def prune(data, now: int):
    keep = {}
    for sid, s in data.get("sessions", {}).items():
        if now - int(s.get("updated_at", 0) or 0) <= SESSION_TTL:
            keep[sid] = s
    data["sessions"] = keep


def main():
    DIR.mkdir(parents=True, exist_ok=True)
    state = (sys.argv[1] if len(sys.argv) > 1 else "idle").strip()
    payload = read_payload()
    session_id = payload.get("session_id") or "_unknown"
    transcript_path = payload.get("transcript_path", "")
    cwd = payload.get("cwd") or os.getcwd()
    project = os.path.basename(cwd) or "unknown"
    now = int(time.time())

    # File lock so concurrent hooks don't clobber each other
    with open(LOCK, "w") as lock_f:
        fcntl.flock(lock_f, fcntl.LOCK_EX)
        data = load_state()
        prune(data, now)

        sessions = data.setdefault("sessions", {})
        entry = sessions.get(session_id, {})

        # Derive label (only need to compute once per session, keep if already set)
        label = entry.get("label") or truncate(first_user_text(transcript_path)) or project

        sessions[session_id] = {
            "state": state,
            "project": project,
            "label": label,
            "updated_at": now,
            "transcript_path": transcript_path,
        }
        save_state(data)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never block Claude Code on hook failure
        sys.exit(0)
