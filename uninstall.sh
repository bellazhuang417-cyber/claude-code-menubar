#!/usr/bin/env bash
# uninstall.sh — 卸载 Claude Code Menubar
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
HOOK_DIR="$HOME/.claude-menubar"
PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "$HOME/Library/Application Support/SwiftBar/Plugins")"

say()  { printf "\033[1;34m▸\033[0m %s\n" "$1"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$1"; }

# 1. remove plugin
if [[ -f "$PLUGIN_DIR/claude.1s.py" ]]; then
  rm "$PLUGIN_DIR/claude.1s.py"
  ok "已移除插件"
fi

# 2. strip hooks from settings.json
if [[ -f "$SETTINGS" ]]; then
  python3 - "$SETTINGS" <<'PYEOF'
import json, sys, time, shutil
p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    try: data = json.load(f)
    except json.JSONDecodeError: sys.exit(0)
shutil.copy(p, p + f".bak.{int(time.time())}")
hooks = data.get("hooks", {})
for ev in list(hooks.keys()):
    hooks[ev] = [e for e in hooks[ev]
                 if not any(("write_status.sh" in h.get("command","")) or ("update_status.py" in h.get("command","")) for h in e.get("hooks", []))]
    if not hooks[ev]:
        del hooks[ev]
if not hooks:
    data.pop("hooks", None)
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PYEOF
  ok "已清理 ~/.claude/settings.json 里的 hooks"
fi

# 3. remove status dir
if [[ -d "$HOOK_DIR" ]]; then
  rm -rf "$HOOK_DIR"
  ok "已删除 $HOOK_DIR"
fi

say "卸载完成。如需完全移除 SwiftBar 本身：brew uninstall --cask swiftbar"
