#!/usr/bin/env bash
# clear.sh — 手动清空状态（菜单栏点"Clear status"调用）
set -euo pipefail
DIR="$HOME/.claude-menubar"
mkdir -p "$DIR"
cat > "$DIR/status.json" <<'EOF'
{"state": "idle", "project": "", "updated_at": 0, "message": ""}
EOF
