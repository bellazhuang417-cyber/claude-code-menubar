# Claude Code Menubar

macOS 菜单栏 Claude Code 状态显示器。**v0.2 改用 Hammerspoon + WebView 重构**，渲染保真度大幅提升；v0.1 的 SwiftBar 路线已弃用（`plugin/claude.1s.py` 留作历史参考）。

定位（v0.3 起升级）：**状态显示器 + 权限遥控器**。它回答「现在有几个 session、谁在等我、等的是什么」，并且权限确认（Allow/Deny）可以直接在面板或 macOS 通知里点掉，不用切窗口。其他操作（回消息）仍然切到对应窗口处理。

## v0.3 新增

### 1. 远程 Allow / Deny（权限遥控）

Claude Code 弹权限确认时：

- **macOS 通知**：弹出「Claude 需要权限 · 项目名」，带 `Allow` 按钮和 `Deny` 下拉项，点了直接生效
- **下拉面板**：权限卡片带 ✓ Allow / ✗ Deny 按钮

原理：`PermissionRequest` hook 挂起等待 `~/.claude-menubar/decisions/<session_id>.json`，菜单栏写入决策后 hook 通过 stdout JSON 直接回答 Claude Code（官方 hook decision 机制）。默认等 120 秒（`CLAUDE_MENUBAR_DECISION_WAIT` 可调，需同步改 app.js 的 `REMOTE_WINDOW`），超时或 Hammerspoon 没在跑就回退到窗口内正常弹窗——原有流程永远兜底。

**为什么只等 120 秒**：hook 挂起期间，Claude Code 窗口内的权限弹窗也会被挂起（官方行为）。等太久 = 你在窗口里也看不到弹窗。120 秒是「够你在通知/面板点一下」和「不长时间卡住窗口流程」的折中。**超过 120 秒后**：面板卡片的按钮会替换成「远程确认已超时——请到窗口处理」提示，系统通知自动收回，不会出现点了没反应的死按钮。

JS→Lua 通信走 WKWebView 官方 message handler（`hs.webview.usercontent`）；旧的 `hammerspoon://` 伪导航被现代 WebKit 静默拦截（v0.2 面板点击失灵的根因），仅留作 fallback。桥的每条消息都会记录到 `~/.claude-menubar/menubar.log`，排障先看这个文件。

> ⚠️ 通知按钮需要把 Hammerspoon 的通知样式设为 **Alerts（提醒）**：系统设置 → 通知 → Hammerspoon → 提醒。Banner 样式按钮悬停才出现。

### 1.5 桌面宠物（v0.3.1）

有会话进入「等你确认」状态时，Tac 会从屏幕右下角跑出来，气泡喊「主子，有需求等你确认！」，副标题显示项目名：

- **点宠物身体** → 直接打开菜单栏面板处理
- **点气泡上的 ×** → 本批需求不再打扰；有**新**需求时会再跑出来
- **需求全部处理完** → 自动离场
- 同一批需求只出场一次，不会每 5 秒重复动画

实现：独立的透明无边框 webview（`pet.lua`），复用 `web/assets/tac-needs-input.svg`（内联 SMIL 动画），走同样的 `usercontent` message bridge。

**称呼规则**：气泡里怎么叫你，按优先级取
1. `~/.claude-menubar/config.json` 里的 `pet_name`（如 `{"pet_name": "Bella"}`）
2. 没有配置时自动用 macOS 用户名（`$USER`）——发版后其他使用者装上即被用自己的用户名称呼，无需配置

### 1.7 皮肤系统（v0.3.3）

宠物形象可以本地换皮。默认自带 Tac（SVG 矢量），也支持任意 sprite-sheet 皮肤：

```
~/.claude-menubar/skins/
├── winkey/
│   ├── manifest.json
│   └── spritesheet.webp
└── muskie/
    ├── manifest.json
    └── spritesheet.webp
```

manifest 描述帧尺寸和每种心情用哪几帧动画（`input` = 走/跑吸引注意，`done` = 挥手/欢呼）。切皮肤：

```bash
hs -c "claudeMenubar.setSkin('muskie')"   # 换 Musk
hs -c "claudeMenubar.setSkin('tac')"      # 换回 Tac
```

或改 `~/.claude-menubar/config.json`：`{"skin": "winkey"}` 然后 `hs -c "hs.reload()"`。

**皮肤只在本机生效**，仓库不带任何第三方 sprite（copyright 卫生）。你可以按 `manifest.json` 格式自己做/找皮肤。

### 1.6 长任务完成播报（v0.3.2）

任务连续跑满 `long_task_seconds`（默认 120 秒）后结束时：

- **系统通知**：「Task finished ✓ · 项目名」+ 会话标题和耗时，人不在时留在通知中心；点通知打开面板
- **桌宠报喜**：绿色气泡「<name>, task finished ✓ — 项目名 · ran 12m」+ 完成态 Tac，25 秒后自动离场；如果宠物正忙着喊你确认权限（pending 优先），只发通知不打断

快问快答（不足阈值的 turn）保持静默，不刷屏。阈值可在 `~/.claude-menubar/config.json` 配置：`{"long_task_seconds": 300}`。

实现：hooks 侧记录 turn 计时（`UserPromptSubmit` 起表，`Stop` 落表写入 `turn_duration`），Lua 侧按 `session_id:updated_at` 去重播报。

### 2. 状态准确性：transcript 对账

hooks 是事件流，事件会丢（插件安装前就开着的 session 不带新 hooks、hook 进程被杀、时序竞争）。v0.3 起每 5 秒 tick 时对比 transcript JSONL 的实际最新事件：transcript 比最后一次 hook 写入新，就以 transcript 为准重新推导状态（用户已回复 → running；工具结果已落盘 → running；最后是 Claude 的文本回答 → done）。

### 3. 状态语义修正

**Stop（回答完成）不再显示为 pending**。之前每个聊完的会话都挂着「needs reply」，看起来像在等你。现在：

| 状态 | 含义 |
|------|------|
| pending | **真的在等你操作**：权限 Allow/Deny、AskUserQuestion 选择 |
| done ✓ | 回答完成，30 分钟后淡出为 idle |
| running | 干活中 |

## 菜单栏图标

| 状态 | 文字 | 含义 |
|------|------|------|
| idle | （无） | 没有活跃 session |
| running | ` N` | N 个 session 在调工具干活 |
| **pending** | ` N!` ↔ ` N ` | **N 个 session 在等你确认**（1Hz 闪烁） |
| done | ` ✓` | 刚回答完，30 分钟后回到 idle |

## 下拉面板

点击菜单栏图标在图标正下方弹出 380px 浮动 WebView：

- Header：`~claude-code · N sessions` + 三色状态计数（run / wait / done）
- Session 列表：每条显示状态色条 + 项目名 + label + 相对时间，**pending 永远置顶**
- 点击 session 行展开：最近 4–6 行 transcript log + 状态相关内容（permission 卡片 / running spinner / done 文案）
- Footer：Open status file / Quit

## 安装

```bash
git clone https://github.com/<your-user>/claude-code-menubar.git
cd claude-code-menubar
./install.sh
```

脚本会：

1. 通过 Homebrew 安装 Hammerspoon（已装则跳过）
2. 把 lua + web 资源拷到 `~/.hammerspoon/claude-menubar/`
3. 把 hooks 拷到 `~/.claude-menubar/`
4. 在 `~/.hammerspoon/init.lua` 追加 require 块（用 marker 防重复）
5. 合并 hooks 到 `~/.claude/settings.json`（PreToolUse → running / Notification → pending / Stop → done）
6. 把 Hammerspoon 加进 Login Items（重启后自启动）
7. 启动 Hammerspoon

**首次启动需要 Accessibility 权限**：

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

授权后菜单栏 cc 图标会出现。

## 卸载

```bash
./uninstall.sh
```

清除 `~/.hammerspoon/claude-menubar/`、`~/.claude-menubar/`、`~/.claude/settings.json` 里的 hooks、Hammerspoon 登录项（会询问），可选保留 Hammerspoon 本体。

## 预览视觉（不装 Hammerspoon）

把 `hammerspoon/claude-menubar/web/app.js` 顶部的 `MOCK_MODE = false` 改成 `true`，然后在浏览器里打开 `hammerspoon/claude-menubar/web/index.html`，会看到 4 条假 session 渲染出来，覆盖 pending（含 permission 卡片）/ pending（无 permission）/ running / done 全部状态。

## 故障排除

- **菜单栏没图标**：打开 Hammerspoon Console（菜单栏 Hammerspoon → Console）看 `[claude-menubar] started` 是否打印；没有就检查 `~/.hammerspoon/init.lua` 里的 require 块是否存在。
- **点图标 WebView 不弹**：检查 Accessibility 权限。Hammerspoon Console 应该会有 alert。
- **WebView 中文糊**：CSS 字体栈已显式列 `"PingFang SC"`，正常应不会糊；如果还糊，看是不是 Hammerspoon 在用很老的 macOS 版本。
- **status.json 不更新**：在 VS Code Claude Code 调一次工具，看 `cat ~/.claude-menubar/status.json` 有没有新 session 条目。没有就检查 `~/.claude/settings.json` 里 hooks 配置。

## 目录结构

```
claude-code-menubar/
├── README.md
├── PRD.md             ← v0.1 PRD（保留）
├── PRD_v0.2.md        ← v0.2 PRD
├── install.sh         ← v0.2 安装脚本
├── uninstall.sh
├── hammerspoon/
│   ├── init-loader.lua    ← init.lua 里追加的代码片段（参考）
│   └── claude-menubar/
│       ├── init.lua       ← 入口 + 渲染调度
│       ├── menubar.lua    ← 菜单栏图标 + title 三态
│       ├── webview.lua    ← WebView 生命周期 + URL scheme bridge
│       ├── transcript.lua ← JSONL 解析（log tail）
│       └── web/
│           ├── index.html
│           ├── styles.css
│           └── app.js
├── hooks/
│   ├── update_status.py   ← 复用 v0.1，加 schema_version / cwd / pending_permission 字段
│   └── clear.sh
└── plugin/                ← v0.1 SwiftBar 实现，已弃用，保留作历史参考
    └── claude.1s.py
```

## 状态文件 schema (v0.2)

`~/.claude-menubar/status.json`：

```json
{
  "schema_version": 2,
  "sessions": {
    "<session_id>": {
      "state": "running|pending|done",
      "project": "demo-project",
      "label": "最近用户消息前 40 字",
      "updated_at": 1747800000,
      "transcript_path": "/Users/.../*.jsonl",
      "cwd": "/Users/you/Projects/demo-project",
      "pending_permission": null
    }
  }
}
```

`pending_permission` 由 PermissionRequest hook 从 payload 解析 tool / command / reason / requested_at，WebView 里展示为可操作的 permission 卡片（v0.3 起带 Allow/Deny 按钮）。

远程决策文件：`~/.claude-menubar/decisions/<session_id>.json`，内容 `{"behavior": "allow"|"deny", "ts": <epoch>}`。由面板按钮或 macOS 通知写入，挂起中的 PermissionRequest hook 轮询消费后即删除。

## License

见 `LICENSE`。
