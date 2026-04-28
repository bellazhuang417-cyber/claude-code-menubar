# Claude Code Menubar

在 macOS 菜单栏显示 Claude Code 当前状态，让你不盯屏幕也能知道 Claude 什么时候在等你、什么时候跑完了。

## 状态图标

| 状态 | 图标 | 含义 |
|------|------|------|
| 闲置 | 💤 | Claude 在睡觉，没活儿 |
| 运行中 | 🤖 ↔ ⚙️ | Claude 在调工具干活（每秒交替） |
| **等你确认** | 👀 ↔ 🙈 | **Claude 在等你批权限**（每秒闪烁） |
| 完成 | 🎉 | 刚回答完，30 秒后回到 💤 |

全程无声，不打扰。

## 安装

```bash
git clone https://github.com/<你的用户名>/claude-code-menubar.git
cd claude-code-menubar
./install.sh
```

脚本会自动：
1. 装 [SwiftBar](https://swiftbar.app/)（通过 Homebrew；已装则跳过）
2. 把插件拷进 SwiftBar 插件目录
3. 把 hook 脚本装到 `~/.claude-menubar/`
4. 把 hook 配置合并进 `~/.claude/settings.json`（会备份原文件）
5. 启动 SwiftBar

## 要求

- macOS
- Homebrew（装 SwiftBar 用；已自己装过 SwiftBar 的可跳过）
- Claude Code CLI
- Python 3（macOS 自带）

## 工作原理

```
Claude Code 事件
    ↓ (Notification / Stop / PreToolUse hook)
~/.claude-menubar/write_status.sh
    ↓ 写入 JSON
~/.claude-menubar/status.json
    ↑ 每秒读
SwiftBar 插件 (claude.1s.py)
    ↓
菜单栏图标
```

- `Notification` hook → `pending`（Claude 需要权限时触发）
- `Stop` hook → `done`（Claude 回答完成时触发）
- `PreToolUse` hook → `running`（Claude 调用工具时触发）

优先级：`pending` > `done` > `running` > `idle`

## 卸载

```bash
./uninstall.sh
```

## 自定义图标

编辑 `plugin/claude.1s.py` 里的 `ICONS` 字典，每个状态是一个 `(图标A, 图标B)` 元组，菜单栏会按秒交替显示。不想闪的话把两个图标写成一样就行。

## License

MIT
