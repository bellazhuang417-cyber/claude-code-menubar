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
import subprocess
import sys
import time
from pathlib import Path

DIR = Path.home() / ".claude-menubar"
FILE = DIR / "status.json"
LOCK = DIR / "status.lock"
DECISIONS_DIR = DIR / "decisions"
SESSION_TTL = 86400  # prune sessions untouched for > 24 hours
LABEL_MAX = 40

# Remote-approve: how long the PermissionRequest hook waits for an Allow/Deny
# clicked in the menubar panel / macOS notification before giving up and
# falling back to the normal in-window permission dialog. Must stay below the
# hook timeout (default 600s). Override: export CLAUDE_MENUBAR_DECISION_WAIT=30
DECISION_WAIT = float(os.environ.get("CLAUDE_MENUBAR_DECISION_WAIT", "120"))
DECISION_POLL = 0.25


def read_payload():
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw.strip() else {}
    except (json.JSONDecodeError, OSError):
        return {}


def _collect_user_messages(transcript_path: str) -> list[str]:
    """Return all meaningful user messages from the transcript, in order.
    Filters out tags, file refs, skill openers, and system noise."""
    if not transcript_path or not os.path.exists(transcript_path):
        return []
    out = []
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
                if text.startswith(("<", "/", "[", "@")):
                    continue
                lowered = text.lower()
                if lowered.startswith(("base directory for", "caveat:", "system:")):
                    continue
                if len(text) < 3:
                    continue
                out.append(text)
    except OSError:
        return []
    return out


def latest_user_text(transcript_path: str) -> str:
    """Most recent meaningful user message — used as session subtitle."""
    msgs = _collect_user_messages(transcript_path)
    return msgs[-1] if msgs else ""


def first_user_text(transcript_path: str) -> str:
    """First meaningful user message — used as stable session title.
    Stays the same as the conversation grows, so each session has a recognizable
    identity even when many sessions share the same cwd/project."""
    msgs = _collect_user_messages(transcript_path)
    return msgs[0] if msgs else ""


# Claude Desktop stores its own auto-generated chat title per session.
# This is the "Improve plugin UI..." style label shown in the Claude Desktop UI.
# Each file looks like:
#   {"cliSessionId": "<our session_id>", "title": "...", "titleSource": "auto", ...}
CLAUDE_DESKTOP_SESSIONS_DIR = os.path.expanduser(
    "~/Library/Application Support/Claude/claude-code-sessions"
)

def claude_desktop_title(session_id: str) -> str:
    """Look up the human-readable title that Claude Desktop assigned to this
    chat. Returns empty string if not found (e.g. session originated from CLI
    instead of Desktop, or files not yet written)."""
    if not session_id or not os.path.isdir(CLAUDE_DESKTOP_SESSIONS_DIR):
        return ""
    # Walk shallow — typical layout is sessions-dir/<workspace>/<sub>/local_*.json
    try:
        for workspace in os.listdir(CLAUDE_DESKTOP_SESSIONS_DIR):
            wp = os.path.join(CLAUDE_DESKTOP_SESSIONS_DIR, workspace)
            if not os.path.isdir(wp):
                continue
            for sub in os.listdir(wp):
                sp = os.path.join(wp, sub)
                if not os.path.isdir(sp):
                    continue
                for fname in os.listdir(sp):
                    if not fname.startswith("local_") or not fname.endswith(".json"):
                        continue
                    fpath = os.path.join(sp, fname)
                    try:
                        with open(fpath, "r", encoding="utf-8") as f:
                            d = json.load(f)
                        if d.get("cliSessionId") == session_id and d.get("title"):
                            return d["title"]
                    except (OSError, json.JSONDecodeError):
                        continue
    except OSError:
        pass
    return ""


def truncate(s: str, n: int = LABEL_MAX) -> str:
    s = " ".join(s.split())  # collapse whitespace
    return s if len(s) <= n else s[: n - 1] + "…"


def load_state():
    if not FILE.exists():
        return {"schema_version": 2, "sessions": {}}
    try:
        with open(FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if "sessions" not in data:
            data = {"schema_version": 2, "sessions": {}}
        # Stamp schema_version on every write so older files self-heal.
        data["schema_version"] = 2
        return data
    except (json.JSONDecodeError, OSError):
        return {"schema_version": 2, "sessions": {}}


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


def _extract_permission_payload(payload: dict) -> dict:
    """Parse PermissionRequest hook stdin and pull out tool/command/reason.

    The exact shape of Claude Code's PermissionRequest payload isn't fully
    documented, so we look in a few likely places. Returns a dict with keys
    {tool, command, reason}, all strings (possibly empty)."""
    out = {"tool": "", "command": "", "reason": ""}
    # Try the structured fields first (newer hook versions).
    out["tool"] = (
        payload.get("tool_name")
        or payload.get("tool")
        or (payload.get("tool_use") or {}).get("name")
        or ""
    )
    tool_input = payload.get("tool_input") or (payload.get("tool_use") or {}).get("input") or {}
    if isinstance(tool_input, dict):
        # Bash → "command"; Edit → "file_path"; others vary
        out["command"] = (
            tool_input.get("command")
            or tool_input.get("file_path")
            or tool_input.get("path")
            or ""
        )
        # Reason may be in description / explanation field
        out["reason"] = (
            tool_input.get("description")
            or tool_input.get("explanation")
            or payload.get("reason")
            or ""
        )
    elif isinstance(tool_input, str):
        out["command"] = tool_input
    # Truncate to keep status.json compact
    out["command"] = (out["command"] or "")[:500]
    out["reason"] = (out["reason"] or "")[:200]
    return out


def _hammerspoon_running() -> bool:
    try:
        return subprocess.run(
            ["pgrep", "-x", "Hammerspoon"], capture_output=True, timeout=5
        ).returncode == 0
    except Exception:
        return False


def _read_session_entry(session_id: str) -> dict:
    """Re-read status.json (no lock; read-only) and return this session's entry."""
    try:
        with open(FILE, "r", encoding="utf-8") as f:
            return json.load(f).get("sessions", {}).get(session_id) or {}
    except (OSError, json.JSONDecodeError):
        return {}


def wait_for_remote_decision(session_id: str):
    """Block until the menubar writes a decision file, the permission gets
    handled elsewhere, or DECISION_WAIT elapses.

    Returns "allow" / "deny" if the user decided from the menubar/notification;
    None means fall through to the normal in-window permission dialog.
    """
    decision_file = DECISIONS_DIR / f"{session_id}.json"
    deadline = time.time() + DECISION_WAIT
    while time.time() < deadline:
        if decision_file.exists():
            try:
                with open(decision_file, "r", encoding="utf-8") as f:
                    behavior = (json.load(f).get("behavior") or "").strip()
            except (OSError, json.JSONDecodeError):
                behavior = ""
            try:
                decision_file.unlink()
            except OSError:
                pass
            return behavior if behavior in ("allow", "deny") else None
        # If another event (PostToolUse, in-window Allow, session end) already
        # cleared the pending permission, stop waiting quietly.
        entry = _read_session_entry(session_id)
        if not entry or entry.get("state") != "pending" or not entry.get("pending_permission"):
            return None
        time.sleep(DECISION_POLL)
    return None


def _apply_remote_decision(session_id: str, behavior: str):
    """Mark the session running + clear the permission card after a remote decision."""
    with open(LOCK, "w") as lock_f:
        fcntl.flock(lock_f, fcntl.LOCK_EX)
        data = load_state()
        entry = data.get("sessions", {}).get(session_id)
        if entry:
            entry["state"] = "running"
            entry["pending_permission"] = None
            entry["updated_at"] = int(time.time())
            save_state(data)


def main():
    DIR.mkdir(parents=True, exist_ok=True)
    cmd = (sys.argv[1] if len(sys.argv) > 1 else "idle").strip()
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

        # Re-derive title and label every event so they stay fresh.
        msgs = _collect_user_messages(transcript_path)
        latest = truncate(msgs[-1]) if msgs else (entry.get("label") or project)
        desktop_title = claude_desktop_title(session_id)
        if desktop_title:
            title = truncate(desktop_title, 80)
        else:
            title = entry.get("title")
            if not title:
                title = truncate(msgs[0]) if msgs else (entry.get("label") or project)

        # ---------- Event dispatch ----------
        # SessionEnd → delete from status.json entirely (chat archived / closed)
        if cmd == "session_end":
            if session_id in sessions:
                del sessions[session_id]
                save_state(data)
            return  # short-circuit; nothing else to write

        if cmd == "permission_request":
            # Claude is asking the user to approve a tool call.
            # state=pending; pending_permission has tool/command/reason for the card.
            new_state = "pending"
            pending_permission = _extract_permission_payload(payload)
            pending_permission["requested_at"] = now
            # Clear any stale decision file so we never consume an old click.
            DECISIONS_DIR.mkdir(parents=True, exist_ok=True)
            stale = DECISIONS_DIR / f"{session_id}.json"
            if stale.exists():
                try:
                    stale.unlink()
                except OSError:
                    pass
        elif cmd == "permission_denied":
            # User clicked Deny. Claude will choose what to do next.
            new_state = "running"
            pending_permission = None
        elif cmd == "post_tool_use":
            # Tool finished. Clear any pending approval state. Don't change
            # state field — Stop / UserPromptSubmit handles that lifecycle.
            prev_state = entry.get("state", "running")
            new_state = "running" if prev_state == "pending" else prev_state
            pending_permission = None
        elif cmd == "stop":
            # Claude finished its turn → done ("回答完成"). We used to write
            # pending here ("needs reply", Claude Desktop semantics), but that
            # made every finished conversation look like it was waiting on the
            # user — the #1 source of "状态显示等待但其实没有" complaints.
            # pending is now reserved for real blocking waits: permission
            # Allow/Deny and mid-turn questions (AskUserQuestion / plan mode).
            new_state = "done"
            pending_permission = None
        elif cmd == "notification":
            # Notification fires for several reasons. Only some mean "blocked
            # waiting on the user"; we inspect the message text to decide.
            message = (payload.get("message") or "").lower()
            prev_state = entry.get("state", "running")
            if "permission" in message:
                # Permission prompt (backup path — PermissionRequest hook is
                # the primary writer and carries tool/command details).
                new_state = "pending"
                pending_permission = entry.get("pending_permission")
            elif "waiting" in message or "input" in message:
                # "Claude is waiting for your input". Genuine mid-turn wait
                # (AskUserQuestion / plan approval) arrives while state is
                # still running. If we already marked the turn done via Stop,
                # this is just the post-turn idle reminder — ignore it.
                if prev_state == "done" or prev_state == "idle":
                    new_state = prev_state
                    pending_permission = None
                else:
                    new_state = "pending"
                    pending_permission = entry.get("pending_permission")
            else:
                # Unknown notification type — don't guess, keep state as-is.
                new_state = prev_state
                pending_permission = entry.get("pending_permission")
        elif cmd == "user_prompt_submit":
            # User just sent a new message → they're "consuming" the previous
            # Claude turn. Clear the awaiting state and go back to running.
            new_state = "running"
            pending_permission = None
        else:
            # Legacy sub-commands: running / pending / done / idle.
            # These map directly to state strings.
            new_state = cmd
            if cmd == "pending":
                pending_permission = entry.get("pending_permission")
            elif cmd == "done" or cmd == "idle":
                pending_permission = None
            else:  # running
                pending_permission = entry.get("pending_permission")

        sessions[session_id] = {
            "state": new_state,
            "project": project,
            "title": title,
            "label": latest,
            "updated_at": now,
            "transcript_path": transcript_path,
            "cwd": cwd,
            "pending_permission": pending_permission,
        }
        save_state(data)

    # ---------- Remote approve (runs AFTER the lock is released) ----------
    # If the menubar is alive, hold this hook open and poll for an Allow/Deny
    # clicked in the panel or the macOS notification. Claude Code shows the
    # normal permission dialog once we exit without a decision (or time out),
    # so the in-window flow always remains as fallback.
    if cmd == "permission_request" and _hammerspoon_running():
        behavior = wait_for_remote_decision(session_id)
        if behavior in ("allow", "deny"):
            _apply_remote_decision(session_id, behavior)
            decision = {"behavior": behavior}
            if behavior == "deny":
                decision["message"] = "Denied from Claude Menubar"
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": decision,
                }
            }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never block Claude Code on hook failure
        sys.exit(0)
