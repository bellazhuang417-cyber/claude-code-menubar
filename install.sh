#!/usr/bin/env bash
# install.sh — Claude Code Menubar v0.2 (Hammerspoon + WebView)
#
# 1. Install Hammerspoon via Homebrew (skip if present)
# 2. Copy lua + web assets to ~/.hammerspoon/claude-menubar/
# 3. Copy hooks/update_status.py + clear.sh to ~/.claude-menubar/
# 4. Append require() line to ~/.hammerspoon/init.lua (idempotent via marker)
# 5. Merge Claude Code hooks into ~/.claude/settings.json (idempotent)
# 6. Initialize empty status file
# 7. Add Hammerspoon to Login Items
# 8. Open Hammerspoon to reload config

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS_DIR="$HOME/.hammerspoon"
HS_PLUGIN_DIR="$HS_DIR/claude-menubar"
HOOK_DIR="$HOME/.claude-menubar"
SETTINGS="$HOME/.claude/settings.json"
INIT_LUA="$HS_DIR/init.lua"
MARKER_BEGIN="-- claude-menubar:require"
MARKER_END="-- claude-menubar:end"

say()  { printf "\033[1;34m▸\033[0m %s\n" "$1"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$1"; }
die()  { printf "\033[1;31m✗\033[0m %s\n" "$1" >&2; exit 1; }

# ---------- 1. Hammerspoon ----------
say "Checking Hammerspoon..."
if [[ -d "/Applications/Hammerspoon.app" ]]; then
  ok "Hammerspoon already installed"
else
  if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew not found. Install Homebrew first (https://brew.sh) then re-run."
  fi
  say "Installing Hammerspoon via Homebrew..."
  brew install --cask hammerspoon
  ok "Hammerspoon installed"
fi

# ---------- 2. Copy lua + web assets ----------
say "Installing Hammerspoon module to $HS_PLUGIN_DIR"
mkdir -p "$HS_PLUGIN_DIR/web"
cp "$REPO_DIR/hammerspoon/claude-menubar/init.lua"       "$HS_PLUGIN_DIR/init.lua"
cp "$REPO_DIR/hammerspoon/claude-menubar/menubar.lua"    "$HS_PLUGIN_DIR/menubar.lua"
cp "$REPO_DIR/hammerspoon/claude-menubar/webview.lua"    "$HS_PLUGIN_DIR/webview.lua"
cp "$REPO_DIR/hammerspoon/claude-menubar/transcript.lua" "$HS_PLUGIN_DIR/transcript.lua"
cp "$REPO_DIR/hammerspoon/claude-menubar/pet.lua"        "$HS_PLUGIN_DIR/pet.lua"
cp "$REPO_DIR/hammerspoon/claude-menubar/desktop_sessions.lua" "$HS_PLUGIN_DIR/desktop_sessions.lua"
cp "$REPO_DIR/hammerspoon/claude-menubar/web/index.html" "$HS_PLUGIN_DIR/web/index.html"
cp "$REPO_DIR/hammerspoon/claude-menubar/web/styles.css" "$HS_PLUGIN_DIR/web/styles.css"
cp "$REPO_DIR/hammerspoon/claude-menubar/web/app.js"     "$HS_PLUGIN_DIR/web/app.js"
mkdir -p "$HS_PLUGIN_DIR/web/assets"
cp "$REPO_DIR/hammerspoon/claude-menubar/web/assets/"*.svg "$HS_PLUGIN_DIR/web/assets/" 2>/dev/null || true
cp "$REPO_DIR/hammerspoon/claude-menubar/web/assets/"*.png "$HS_PLUGIN_DIR/web/assets/" 2>/dev/null || true
ok "Module copied"

# ---------- 3. Copy hooks ----------
say "Installing hook scripts to $HOOK_DIR"
mkdir -p "$HOOK_DIR"
cp "$REPO_DIR/hooks/update_status.py" "$HOOK_DIR/update_status.py"
cp "$REPO_DIR/hooks/clear.sh" "$HOOK_DIR/clear.sh"
chmod +x "$HOOK_DIR/update_status.py" "$HOOK_DIR/clear.sh"
rm -f "$HOOK_DIR/write_status.sh"  # legacy v1 cleanup
ok "Hooks installed"

# ---------- 4. init.lua require ----------
say "Wiring up ~/.hammerspoon/init.lua"
mkdir -p "$HS_DIR"
touch "$INIT_LUA"
if grep -qF -e "$MARKER_BEGIN" "$INIT_LUA"; then
  ok "require block already present (skipping)"
else
  {
    echo ""
    echo "$MARKER_BEGIN  (do not remove this marker — install/uninstall use it)"
    echo 'package.path = package.path .. ";" .. os.getenv("HOME") .. "/.hammerspoon/claude-menubar/?.lua"'
    echo 'local claudeMenubar = dofile(os.getenv("HOME") .. "/.hammerspoon/claude-menubar/init.lua")'
    echo 'claudeMenubar.start()'
    echo "$MARKER_END"
  } >> "$INIT_LUA"
  ok "require block appended"
fi

# ---------- 5. Initialize status file ----------
if [[ ! -f "$HOOK_DIR/status.json" ]]; then
  echo '{"schema_version":2,"sessions":{}}' > "$HOOK_DIR/status.json"
  ok "Empty status.json created"
fi

# ---------- 6. Merge Claude Code hooks ----------
say "Updating Claude Code hooks config..."
mkdir -p "$(dirname "$SETTINGS")"
if [[ ! -f "$SETTINGS" ]]; then
  echo '{}' > "$SETTINGS"
fi

python3 - "$SETTINGS" "$HOOK_DIR" <<'PYEOF'
import json, sys, os, shutil, time
settings_path, hook_dir = sys.argv[1], sys.argv[2]
update_cmd = os.path.join(hook_dir, "update_status.py")

with open(settings_path, "r", encoding="utf-8") as f:
    try:
        data = json.load(f)
    except json.JSONDecodeError:
        data = {}

shutil.copy(settings_path, settings_path + f".bak.{int(time.time())}")

hooks = data.setdefault("hooks", {})

# Drop any legacy entries that pointed to v1 write_status.sh
for event in list(hooks.keys()):
    hooks[event] = [
        e for e in hooks[event]
        if not any("write_status.sh" in h.get("command", "") for h in e.get("hooks", []))
    ]
    if not hooks[event]:
        del hooks[event]

# v0.3 migration: Notification used to map straight to "pending"; it now goes
# through the smarter "notification" dispatcher (distinguishes permission /
# waiting-for-input / other notification types).
for entry in hooks.get("Notification", []):
    for h in entry.get("hooks", []):
        if h.get("command", "").endswith("update_status.py pending"):
            h["command"] = h["command"].replace(
                "update_status.py pending", "update_status.py notification")

def ensure_hook(event: str, state: str):
    entries = hooks.setdefault(event, [])
    marker = f"update_status.py {state}"
    for entry in entries:
        for h in entry.get("hooks", []):
            if marker in h.get("command", ""):
                return
    entries.append({
        "hooks": [{
            "type": "command",
            "command": f'{update_cmd} {state}'
        }]
    })

ensure_hook("Notification", "notification")
ensure_hook("PreToolUse", "running")
# v0.2.2: event-driven needs_input detection.
# v0.3: permission_request also blocks waiting for a remote Allow/Deny from
# the menubar panel / macOS notification (falls back to the normal in-window
# dialog after CLAUDE_MENUBAR_DECISION_WAIT seconds, default 120).
ensure_hook("PermissionRequest", "permission_request")
ensure_hook("PermissionDenied",  "permission_denied")
ensure_hook("PostToolUse",       "post_tool_use")
# v0.3: Stop = "turn finished" → done. pending is reserved for real blocking
# waits (permission Allow/Deny, mid-turn questions).
ensure_hook("Stop", "stop")
ensure_hook("UserPromptSubmit", "user_prompt_submit")
ensure_hook("SessionEnd", "session_end")

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print("merged")
PYEOF
ok "Hooks merged (backup at settings.json.bak.<timestamp>)"

# ---------- 7. Login item ----------
say "Adding Hammerspoon to Login Items..."
osascript <<'AS' >/dev/null 2>&1 || warn "Could not add login item automatically — add Hammerspoon to System Settings → General → Login Items manually."
tell application "System Events"
  if not (exists login item "Hammerspoon") then
    make login item at end with properties {name:"Hammerspoon", path:"/Applications/Hammerspoon.app", hidden:false}
  end if
end tell
AS
ok "Login item set"

# ---------- 8. Launch / reload Hammerspoon ----------
if pgrep -x Hammerspoon >/dev/null; then
  say "Hammerspoon running — reloading config..."
  osascript -e 'tell application "Hammerspoon" to reload config' 2>/dev/null || true
else
  open -a Hammerspoon
fi
ok "Hammerspoon launched"

cat <<'EOF'

──────────────────────────────────────────
✅ Installed.

If this is your first time launching Hammerspoon, macOS will ask for
Accessibility permission. Grant it from:
  System Settings → Privacy & Security → Accessibility → Hammerspoon

Quick open: open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

You should see the cc icon in the menubar. Trigger Claude Code in any
window — the title will animate as state changes.

Uninstall: ./uninstall.sh
──────────────────────────────────────────
EOF
