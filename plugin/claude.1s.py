#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# <bitbar.title>Claude Code Status</bitbar.title>
# <bitbar.version>v2.0</bitbar.version>
# <bitbar.author>Bella</bitbar.author>
# <bitbar.desc>Show Claude Code activity status per session in the menubar.</bitbar.desc>
# <bitbar.dependencies>python3</bitbar.dependencies>
#
# <swiftbar.hideAbout>false</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>false</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>

import json
import os
import time
from pathlib import Path

STATUS_FILE = Path.home() / ".claude-menubar" / "status.json"
CLEAR_SCRIPT = Path.home() / ".claude-menubar" / "clear.sh"
DONE_TTL_SECONDS = 30
SESSION_LIST_TTL = 1800  # hide sessions from menu after 30 min of no activity

# (icon_a, icon_b) — alternates every second. Same = no flicker.
ICONS = {
    "idle":    ("💤", "💤"),
    "running": ("🤖", "⚙️"),
    "pending": ("👀", "🙈"),
    "done":    ("🎉", "🎉"),
}

LABELS = {
    "idle":    "睡觉中",
    "running": "干活中",
    "pending": "等你确认",
    "done":    "完成了",
}

PRIORITY = {"pending": 3, "running": 2, "done": 1, "idle": 0}


def read_status():
    if not STATUS_FILE.exists():
        return {"sessions": {}}
    try:
        with open(STATUS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if "sessions" not in data:
            return {"sessions": {}}
        return data
    except (json.JSONDecodeError, OSError):
        return {"sessions": {}}


def effective_state(s: dict, now: int) -> str:
    state = s.get("state", "idle")
    # done auto-expires
    if state == "done" and now - int(s.get("updated_at", 0) or 0) > DONE_TTL_SECONDS:
        return "idle"
    return state


def pick_icon(state: str) -> str:
    pair = ICONS.get(state, ICONS["idle"])
    return pair[int(time.time()) % 2]


def human_ago(ts: int) -> str:
    if not ts:
        return "—"
    delta = int(time.time()) - int(ts)
    if delta < 5:
        return "刚刚"
    if delta < 60:
        return f"{delta} 秒前"
    if delta < 3600:
        return f"{delta // 60} 分钟前"
    if delta < 86400:
        return f"{delta // 3600} 小时前"
    return f"{delta // 86400} 天前"


def escape_bar(s: str) -> str:
    # SwiftBar treats '|' as separator; escape so it stays in label
    return s.replace("|", "¦")


def main():
    now = int(time.time())
    data = read_status()
    sessions = data.get("sessions", {})

    # Decorate with effective state, drop old sessions
    items = []
    for sid, s in sessions.items():
        if now - int(s.get("updated_at", 0) or 0) > SESSION_LIST_TTL:
            continue
        eff = effective_state(s, now)
        items.append({
            "id": sid,
            "state": eff,
            "project": s.get("project", ""),
            "label": s.get("label", "") or s.get("project", ""),
            "updated_at": int(s.get("updated_at", 0) or 0),
        })

    # Menubar icon: highest-priority state across sessions
    top_state = "idle"
    if items:
        top_state = max((i["state"] for i in items), key=lambda st: PRIORITY.get(st, 0))

    icon = pick_icon(top_state)

    # Sort sessions: priority desc, then recency desc
    items.sort(key=lambda i: (-PRIORITY.get(i["state"], 0), -i["updated_at"]))

    # --- SwiftBar output ---
    print(f"{icon} | size=14")
    print("---")

    if not items:
        print(f"Claude Code · {LABELS['idle']}")
        print("当前没有活跃会话 | color=gray")
    else:
        print(f"Claude Code · {len(items)} 个会话")
        print("---")
        for i in items:
            state_icon = ICONS[i["state"]][0]
            state_label = LABELS[i["state"]]
            title = escape_bar(i["label"])
            print(f"{state_icon}  {title}")
            print(f"— {state_label} · {escape_bar(i['project'])} · {human_ago(i['updated_at'])} | color=gray size=11")

    print("---")
    print(f"Clear all | bash='{CLEAR_SCRIPT}' terminal=false refresh=true")
    print(f"Open status file | bash='/usr/bin/open' param1='{STATUS_FILE}' terminal=false")
    print("Refresh now | refresh=true")


if __name__ == "__main__":
    main()
