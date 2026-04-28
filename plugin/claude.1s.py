#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# <bitbar.title>Claude Code Status</bitbar.title>
# <bitbar.version>v1.0</bitbar.version>
# <bitbar.author>Bella</bitbar.author>
# <bitbar.desc>Show Claude Code activity status in the menubar.</bitbar.desc>
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
DONE_TTL_SECONDS = 30

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


def read_status():
    if not STATUS_FILE.exists():
        return {"state": "idle", "project": "", "updated_at": 0, "message": ""}
    try:
        with open(STATUS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"state": "idle", "project": "", "updated_at": 0, "message": ""}


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


def main():
    status = read_status()
    state = status.get("state", "idle")
    updated_at = int(status.get("updated_at", 0) or 0)

    if state == "done" and updated_at and (time.time() - updated_at > DONE_TTL_SECONDS):
        state = "idle"

    icon = pick_icon(state)
    project = status.get("project", "") or "—"
    message = status.get("message", "") or LABELS.get(state, "")

    print(f"{icon} | size=14")
    print("---")
    print(f"Claude Code · {LABELS.get(state, state)}")
    print(f"项目：{project} | color=gray")
    print(f"更新：{human_ago(updated_at)} | color=gray")
    if message:
        print(f"信息：{message} | color=gray")
    print("---")
    print(f"Clear status | bash='{os.path.expanduser('~')}/.claude-menubar/clear.sh' terminal=false refresh=true")
    print(f"Open status file | bash='/usr/bin/open' param1='{STATUS_FILE}' terminal=false")
    print("About | href=https://github.com/")


if __name__ == "__main__":
    main()
