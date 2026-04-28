#!/usr/bin/env bash
# write_status.sh — Claude Code hook → 写状态文件给菜单栏插件读
#
# Usage (from ~/.claude/settings.json):
#   /path/to/write_status.sh <state>
# where <state> is one of: running | pending | done | idle

set -euo pipefail

STATE="${1:-idle}"
DIR="$HOME/.claude-menubar"
FILE="$DIR/status.json"
TMP="$DIR/status.json.tmp"

mkdir -p "$DIR"

PROJECT="$(basename "${PWD:-unknown}")"
TS="$(date +%s)"

case "$STATE" in
  running) MSG="Claude 在干活" ;;
  pending) MSG="需要你确认权限" ;;
  done)    MSG="回答完成" ;;
  idle)    MSG="" ;;
  *)       MSG="" ;;
esac

# Escape double quotes in project / message
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

cat > "$TMP" <<EOF
{
  "state": "$(esc "$STATE")",
  "project": "$(esc "$PROJECT")",
  "updated_at": $TS,
  "message": "$(esc "$MSG")"
}
EOF

mv "$TMP" "$FILE"
