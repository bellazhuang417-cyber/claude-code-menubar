#!/usr/bin/env bash
# uninstall.sh — Claude Code Menubar v0.2 uninstaller
#
# Removes:
#   - ~/.hammerspoon/claude-menubar/ (lua + web assets)
#   - require() block in ~/.hammerspoon/init.lua (located by marker)
#   - update_status.py hooks in ~/.claude/settings.json
#   - ~/.claude-menubar/ (hooks + status.json)
#   - Hammerspoon login item (asks first)
#   - Legacy v0.1 SwiftBar plugin if still present
#
# Does NOT uninstall Hammerspoon itself — user may use it for other things.

set -euo pipefail

HS_DIR="$HOME/.hammerspoon"
HS_PLUGIN_DIR="$HS_DIR/claude-menubar"
INIT_LUA="$HS_DIR/init.lua"
HOOK_DIR="$HOME/.claude-menubar"
SETTINGS="$HOME/.claude/settings.json"
MARKER_BEGIN="-- claude-menubar:require"
MARKER_END="-- claude-menubar:end"

say()  { printf "\033[1;34m▸\033[0m %s\n" "$1"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$1"; }

# 1. Remove module dir
if [[ -d "$HS_PLUGIN_DIR" ]]; then
  rm -rf "$HS_PLUGIN_DIR"
  ok "Removed $HS_PLUGIN_DIR"
fi

# 2. Strip require block from init.lua via markers
if [[ -f "$INIT_LUA" ]] && grep -qF -e "$MARKER_BEGIN" "$INIT_LUA"; then
  python3 - "$INIT_LUA" "$MARKER_BEGIN" "$MARKER_END" <<'PYEOF'
import sys, re
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()
# Remove everything from MARKER_BEGIN line through MARKER_END line, inclusive.
pattern = re.compile(
    r"\n?" + re.escape(begin) + r".*?" + re.escape(end) + r"\n?",
    re.DOTALL,
)
new_text = pattern.sub("\n", text)
with open(path, "w", encoding="utf-8") as f:
    f.write(new_text)
PYEOF
  ok "Stripped require block from init.lua"
fi

# 3. Strip hooks from settings.json (matches update_status.py and legacy write_status.sh)
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
    hooks[ev] = [
        e for e in hooks[ev]
        if not any(
            ("write_status.sh" in h.get("command","")) or
            ("update_status.py" in h.get("command",""))
            for h in e.get("hooks", [])
        )
    ]
    if not hooks[ev]:
        del hooks[ev]
if not hooks:
    data.pop("hooks", None)
with open(p, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PYEOF
  ok "Cleaned hooks from $SETTINGS (backup at .bak.<timestamp>)"
fi

# 4. Remove status dir
if [[ -d "$HOOK_DIR" ]]; then
  rm -rf "$HOOK_DIR"
  ok "Removed $HOOK_DIR"
fi

# 5. Legacy v0.1 SwiftBar plugin cleanup (best-effort)
LEGACY_PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "$HOME/Library/Application Support/SwiftBar/Plugins")"
if [[ -f "$LEGACY_PLUGIN_DIR/claude.1s.py" ]]; then
  rm "$LEGACY_PLUGIN_DIR/claude.1s.py"
  ok "Removed legacy v0.1 SwiftBar plugin"
fi

# 6. Login item (ask)
printf "Remove Hammerspoon from Login Items? [y/N] "
read -r ans || ans=""
if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
  osascript <<'AS' >/dev/null 2>&1 || warn "Could not remove login item automatically"
tell application "System Events"
  if exists login item "Hammerspoon" then delete login item "Hammerspoon"
end tell
AS
  ok "Login item removed"
fi

# 7. Reload Hammerspoon so the live menubar item disappears
if pgrep -x Hammerspoon >/dev/null; then
  osascript -e 'tell application "Hammerspoon" to reload config' 2>/dev/null || true
fi

cat <<'EOF'

──────────────────────────────────────────
Uninstall complete.

Hammerspoon itself was left installed. If you want to remove it:
  brew uninstall --cask hammerspoon
──────────────────────────────────────────
EOF
