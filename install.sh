#!/usr/bin/env bash
# install.sh — Claude Code Menubar 一键安装
#
# 做四件事：
# 1. 装 SwiftBar（如果没装）
# 2. 拷 plugin 到 SwiftBar 插件目录
# 3. 拷 hooks 到 ~/.claude-menubar/
# 4. 把 hook 配置合并进 ~/.claude/settings.json
# 5. 初始化状态文件 + 启动 SwiftBar

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_DIR="$HOME/.claude-menubar"
SETTINGS="$HOME/.claude/settings.json"
PLUGIN_DEFAULT_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"

say()  { printf "\033[1;34m▸\033[0m %s\n" "$1"; }
ok()   { printf "\033[1;32m✓\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$1"; }
die()  { printf "\033[1;31m✗\033[0m %s\n" "$1" >&2; exit 1; }

# ---------- 1. SwiftBar ----------
say "检查 SwiftBar..."
if [[ -d "/Applications/SwiftBar.app" ]]; then
  ok "SwiftBar 已安装"
else
  if ! command -v brew >/dev/null 2>&1; then
    die "没检测到 Homebrew。先装 Homebrew（https://brew.sh），或手动从 https://swiftbar.app 下载 SwiftBar 再重跑本脚本"
  fi
  say "用 Homebrew 安装 SwiftBar..."
  brew install --cask swiftbar
  ok "SwiftBar 已安装"
fi

# ---------- 2. 复制 hooks 脚本 ----------
say "安装 hook 脚本到 $HOOK_DIR"
mkdir -p "$HOOK_DIR"
cp "$REPO_DIR/hooks/write_status.sh" "$HOOK_DIR/write_status.sh"
cp "$REPO_DIR/hooks/clear.sh" "$HOOK_DIR/clear.sh"
chmod +x "$HOOK_DIR/write_status.sh" "$HOOK_DIR/clear.sh"
ok "hook 脚本就位"

# ---------- 3. 初始化状态文件 ----------
if [[ ! -f "$HOOK_DIR/status.json" ]]; then
  bash "$HOOK_DIR/clear.sh"
fi

# ---------- 4. 定位 SwiftBar 插件目录 ----------
say "查找 SwiftBar 插件目录..."
PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [[ -z "$PLUGIN_DIR" ]]; then
  PLUGIN_DIR="$PLUGIN_DEFAULT_DIR"
  mkdir -p "$PLUGIN_DIR"
  defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGIN_DIR"
  warn "SwiftBar 插件目录未设置，已写入默认值：$PLUGIN_DIR"
fi
ok "插件目录：$PLUGIN_DIR"
cp "$REPO_DIR/plugin/claude.1s.py" "$PLUGIN_DIR/claude.1s.py"
chmod +x "$PLUGIN_DIR/claude.1s.py"
ok "插件已拷贝"

# ---------- 5. 合并 hooks 到 ~/.claude/settings.json ----------
say "更新 Claude Code hooks 配置..."
mkdir -p "$(dirname "$SETTINGS")"
if [[ ! -f "$SETTINGS" ]]; then
  echo '{}' > "$SETTINGS"
fi

python3 - "$SETTINGS" "$HOOK_DIR" <<'PYEOF'
import json, sys, os, shutil, time
settings_path, hook_dir = sys.argv[1], sys.argv[2]
write_status = os.path.join(hook_dir, "write_status.sh")

with open(settings_path, "r", encoding="utf-8") as f:
    try:
        data = json.load(f)
    except json.JSONDecodeError:
        data = {}

shutil.copy(settings_path, settings_path + f".bak.{int(time.time())}")

hooks = data.setdefault("hooks", {})

def ensure_hook(event: str, state: str):
    entries = hooks.setdefault(event, [])
    marker = f"write_status.sh {state}"
    for entry in entries:
        for h in entry.get("hooks", []):
            if marker in h.get("command", ""):
                return
    entries.append({
        "hooks": [{
            "type": "command",
            "command": f'{write_status} {state}'
        }]
    })

ensure_hook("Notification", "pending")
ensure_hook("Stop", "done")
ensure_hook("PreToolUse", "running")

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print("merged")
PYEOF
ok "hooks 已合并（原文件已备份为 settings.json.bak.<时间戳>）"

# ---------- 6. 启动 SwiftBar ----------
if pgrep -x SwiftBar >/dev/null; then
  say "SwiftBar 正在运行，刷新插件..."
  osascript -e 'tell application "SwiftBar" to quit' 2>/dev/null || true
  sleep 1
fi
open -a SwiftBar
ok "SwiftBar 已启动"

cat <<'EOF'

──────────────────────────────────────────
🎉 装好了！

现在菜单栏应该能看到 💤 图标。
去 VS Code 打开一个 Claude Code 会话试一下：
  • Claude 调用工具时     → 🤖 ↔ ⚙️ 交替
  • Claude 问你权限时     → 👀 ↔ 🙈 闪烁
  • Claude 回答完成时     → 🎉 (30 秒后回到 💤)

想重置状态：点菜单栏图标 → Clear status
卸载：删掉 SwiftBar 插件目录里的 claude.1s.py 即可
──────────────────────────────────────────
EOF
