#!/usr/bin/env bash
# clear.sh — 手动清空所有 session 状态
set -euo pipefail
DIR="$HOME/.claude-menubar"
mkdir -p "$DIR"
cat > "$DIR/status.json" <<'EOF'
{"sessions": {}}
EOF
