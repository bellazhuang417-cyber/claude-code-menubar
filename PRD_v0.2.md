# Claude Code Menubar — PRD v0.2

> **本文件覆盖范围**：v0.2（Hammerspoon + WebView 重构版）。
> **v0.1 已发布版本**保留在同目录 `PRD.md`，作为历史/已发布状态参考。本文件不重复 v0.1 已经写清楚的背景与目标，只写 v0.2 的增量。
> **面向读者**：负责实施 v0.2 的开发 agent / 协作者。读完应能直接进入开发，不再回头问 Bella 任何架构问题。

---

## 1. 版本说明：v0.2 相对 v0.1 改了什么

### 1.1 v0.1 做到了什么

v0.1 用 **SwiftBar + Python plugin（每秒 stdout）+ Bash/Python hooks + JSON 状态文件** 跑通了一条最小闭环：Claude Code 触发 hook → hook 写 `~/.claude-menubar/status.json` → SwiftBar 插件每秒读文件 → 用 emoji + label 渲染下拉菜单。状态机覆盖 idle / running / pending / done 四态，按 session 聚合，文件锁防并发覆盖。

### 1.2 v0.2 为什么要改

v0.1 的 SwiftBar 路线撞到三个用 stdout 渲染解决不了的天花板：

1. **视觉天花板**：SwiftBar 只能用 emoji + 简单菜单项，没法呈现 design handoff 里的卡片化 session 行、状态色条、展开 log、permission 命令块这些元素。Bella 拿到一份完整 HTML/CSS 设计稿，想保留视觉保真度。
2. **交互天花板**：SwiftBar 菜单是系统下拉菜单，能放的只有「菜单项 + 点击执行 bash」，没法做点击展开、内嵌按钮、log 滚动、注意力色条脉冲这些交互。
3. **刷新模型粗糙**：每秒重启 Python 进程读文件，再 stdout 全量重绘，状态切换的动画/脉冲只能靠 `time.time() % 2` 这种取巧做闪烁。

### 1.3 v0.2 的技术路线（已拍板，不再讨论）

- **菜单栏宿主**：Hammerspoon（替换 SwiftBar）
- **渲染**：Hammerspoon 启动一个浮动 WebView（`hs.webview`），点击菜单栏图标时显示在图标正下方，渲染 HTML/CSS
- **Hooks**：完全复用 v0.1 的 Python 实现（`hooks/update_status.py` 一行不动），continues to write `~/.claude-menubar/status.json`
- **WebView 内容**：以 design handoff 的 `styles.css` + `session-row.jsx` 渲染逻辑为起点，移植成纯 HTML + 原生 JS（不引入 React 构建链）
- **零付费**：不签名、不公证、不开 Apple Developer 账号；用户走 Hammerspoon 自身的 Accessibility 授权

### 1.4 保留不变

| 不变的东西 | 说明 |
|---|---|
| Hooks 全套 Python 实现 | `hooks/update_status.py` 完整保留，包括 fcntl 文件锁、按 session_id 聚合、从 transcript JSONL 抽 label 的逻辑 |
| 状态文件位置 | 仍是 `~/.claude-menubar/status.json` |
| 触发事件映射 | `PreToolUse → running`、`Notification → pending`、`Stop → done` |
| 状态优先级 | `pending > done > running > idle` |
| Done 自动过期 | 30 秒 |
| Session 列表 TTL | 30 分钟不更新就从下拉里隐藏，1 小时后从文件物理删除 |

### 1.5 v0.2 移除/不做

- **移除**：SwiftBar 依赖、plugin 目录、`claude.1s.py` 整文件
- **不做**：Toast banner（菜单关闭时的右上角横幅）
- **不做**：filter tabs（all/working/waiting/done 切换）
- **不做**：10 个 bot avatar 角色化（视觉上用 SF Symbol 或单色 dot 代替，保留 avatar 槽位以后再补）
- **不做（降到 v0.3）**：菜单栏内直接 allow/deny。v0.2 只在 WebView 里**展示**待批权限的内容（命令文本、tool 名、reason），Bella 看完后自己切到对应 Claude Code 客户端窗口处理

### 1.6 设计哲学：状态显示器，不是动作触发器

> [v0.2.1 修订] 此章节按"纯状态显示器"定位新增

这个插件是**状态显示器**，不是**动作触发器**。它只回答一件事：「现在有几个 session、谁在等我、等的是什么内容」。看完之后 Bella 自己切到对应窗口（VS Code / Claude Desktop / Terminal 任一）处理，靠 macOS 自身的 Cmd-Tab / Mission Control 做窗口切换。

引用 Bella 原话："**它可能就是一个状态机**。我今天无论是用 desktop 的 Claude Code 还是 VS Code 或者 terminal，我都可以自己去打开那个窗口。"

因此**插件不假设用户跑 Claude Code 的客户端是 VS Code，不打开任何外部应用**。类比：桌面 CPU 监控小工具——只显示占用率，不替你 kill 进程。

---

## 2. 用户故事

> [v0.2.1 修订] 此章节按"纯状态显示器"定位重写
>
> v0.1 的 US-1 ~ US-3（菜单栏感知状态、pending 时吸引注意、done 后短暂提示）继续有效，不重复列。下面只写 v0.2 新增/修改的。

### US-A：一眼读完所有活跃会话

**作为** Bella，**当** 我同时跑 3 个 Claude Code 窗口，**我希望** 点一下菜单栏图标就能在一个面板里看到 3 个 session 各自状态、当前问题、最近改了哪个项目。
**判定**：点击菜单栏图标后 200ms 内 WebView 弹出；每条 session 显示状态色条 + 项目名 + label + 距上次更新的相对时间；列表按「pending 永远置顶 → 其余按最近更新」排序。

### US-B：展开看到 Claude 最近在干什么

**作为** Bella，**当** 我对某条 session 不确定它卡在哪，**我希望** 点击那一行后展开看到最近 4–6 行对话/工具日志。
**判定**：点击 session 行后该行展开；展开区显示从 `transcript_path` JSONL 解析出的最近 4–6 条消息（用户文本、助手文本、tool_use 名称各一行）；再次点击或点击其他行时折叠。

### US-C：看到待批权限的内容（不操作）

**作为** Bella，**当** 一条 session 处于 pending 状态且是权限请求，**我希望** 展开时看到 Claude 要执行的命令文本 + tool 名 + 理由，让我决定自己接下来怎么处理（去哪个客户端窗口、做什么动作）。
**判定**：pending 且 `pending_permission` 字段非空时，展开区显示一个 permission 卡片，包含 tool 名（如 `bash` / `edit`）、命令/动作文本（等宽字体）、reason 一行说明。**卡片只展示，不带任何跳转按钮**。

### US-D：装好后不用每天手动启动

**作为** Bella，**当** 我重启 Mac，**我希望** Hammerspoon 自启动、Claude Code Menubar 配置自动加载，不用手动操作。
**判定**：`install.sh` 跑完后，Hammerspoon 在登录项里；重启后菜单栏图标自动出现。

### US-E：Pending session 永远第一眼看到

**作为** Bella，**当** 列表里有任何处于 pending 状态的 session（哪怕它已经等了 30 分钟），**我希望** 它永远排在 WebView 列表最顶部，不被更新更新鲜的 running session 挤下去。
**判定**：手测——制造一条 30 分钟前的 pending session 和一条 1 分钟前的 running session，pending 仍排在 running 之前。

---

## 3. 架构图

```
┌─────────────────────────────────────────────────────────────┐
│  Claude Code（VS Code 内）                                  │
│     │                                                       │
│     │ 触发 hook (PreToolUse / Notification / Stop)           │
│     ▼                                                       │
│  ┌─────────────────────────────────────┐                    │
│  │ hooks/update_status.py（v0.1 原样）  │  ← Python，不动     │
│  │  - 读 stdin payload                  │                    │
│  │  - 解析 transcript_path 抽 label     │                    │
│  │  - fcntl.LOCK_EX 文件锁              │                    │
│  └─────────────────────────────────────┘                    │
│            │ 写                                              │
│            ▼                                                 │
│     ~/.claude-menubar/status.json   ← 中间层，单一数据源     │
│            ▲ 读                                              │
│            │                                                 │
│  ┌─────────────────────────────────────┐                    │
│  │ Hammerspoon Lua（init.lua + 模块）   │  ← 新增            │
│  │  - hs.menubar：菜单栏图标 + 徽章     │                    │
│  │  - hs.pathwatcher：监听 status.json  │                    │
│  │  - hs.timer：相对时间 / done 过期    │                    │
│  │  - hs.webview：浮动面板，渲染 HTML   │                    │
│  └─────────────────────────────────────┘                    │
│            │ loadString / setHTML                            │
│            ▼                                                 │
│     WebView：HTML + CSS + JS                                 │
│       - 从 Lua 注入 sessions JSON                            │
│       - 点击事件回调 Lua（hs.webview policy）                │
└─────────────────────────────────────────────────────────────┘
```

**核心分层**：
- **Hooks 层（Python）**：唯一写状态文件的人。完全复用 v0.1。
- **状态文件层（JSON）**：单一数据源。读写两端都不知道对方存在，靠文件解耦。
- **Hammerspoon 层（Lua）**：菜单栏图标、文件监听、WebView 生命周期、Lua↔JS 通信。
- **WebView 层（HTML/CSS/JS）**：渲染逻辑、动画、点击事件。

---

## 4. 状态文件 schema v0.2（向 v0.3 兼容）

文件位置：`~/.claude-menubar/status.json`

### 4.1 顶层结构

```json
{
  "schema_version": 2,
  "sessions": {
    "<session_id>": { ... }
  }
}
```

`schema_version` 是新增字段，v0.2 写 `2`。读端遇到没有此字段的旧文件视为 `1`，仍能解析（向后兼容）。

### 4.2 单个 session 完整示例

```json
{
  "schema_version": 2,
  "sessions": {
    "6867152e-9055-46e6-838f-33968015e76c": {
      "state": "pending",
      "project": "demo-project",
      "label": "帮我加一个菜单栏通知…",
      "updated_at": 1747800000,
      "transcript_path": "~/.claude/projects/.../xxx.jsonl",
      "cwd": "/Users/you/Projects/demo-project",
      "pending_permission": {
        "tool": "bash",
        "command": "rm -rf node_modules && npm install",
        "reason": "Claude wants to reinstall dependencies after dependency change"
      }
    },
    "89a51fec-a77f-414a-9746-b54db179cb3b": {
      "state": "running",
      "project": "demo-project-b",
      "label": "Content Health Check V9 迭代…",
      "updated_at": 1747800010,
      "transcript_path": "~/.claude/projects/.../yyy.jsonl",
      "cwd": "/Users/you/Projects/demo-project-b",
      "pending_permission": null
    }
  }
}
```

### 4.3 字段说明

| 字段 | 类型 | 必填 | v0.2 写入者 | 说明 |
|---|---|---|---|---|
| `schema_version` | int | 是 | hooks | 当前为 `2` |
| `sessions` | object | 是 | hooks | key 为 Claude `session_id` |
| `sessions[].state` | string | 是 | hooks | `idle` / `running` / `pending` / `done` |
| `sessions[].project` | string | 是 | hooks | `basename(cwd)` |
| `sessions[].label` | string | 是 | hooks | transcript 解析出的最近用户消息前 40 字 |
| `sessions[].updated_at` | int | 是 | hooks | epoch seconds |
| `sessions[].transcript_path` | string | 是 | hooks | JSONL 完整路径，WebView 展开时再次解析最近日志 |
| `sessions[].cwd` | string | 是（v0.2 新增） | hooks | 仅用于在 WebView 里展示这是哪个项目的 session，**不再用于打开外部应用** |
| `sessions[].pending_permission` | object\|null | 否（v0.2 新增预留） | **v0.3 才写入；v0.2 hooks 写 `null`** | 见下 |

### 4.4 `pending_permission` 子结构（v0.3 写入，v0.2 仅展示）

```json
{
  "tool": "bash",
  "command": "rm -rf node_modules && npm install",
  "reason": "Claude wants to reinstall dependencies after dependency change"
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `tool` | string | Claude 申请的工具名（`bash` / `edit` / `fetch` / `write` 等） |
| `command` | string | 待批命令或动作的完整文本（等宽展示，可能多行） |
| `reason` | string | Claude 给的执行理由，一句话 |

**v0.2 行为**：hooks 不解析 Notification payload 里的权限详情，`pending_permission` 始终写 `null`。WebView 渲染时检查此字段：为 `null` 则展开区只显示纯文案「Waiting for your response — switch to your Claude Code window」（无按钮）；非 `null` 时按 design handoff 的 permission 卡片样式展示（同样无按钮）。

**v0.3 计划**：扩充 `update_status.py`，从 Notification hook 的 stdin payload 里提取 tool / command / reason 写入此字段，并在 WebView 里加上 allow/deny 按钮直接回写到 Claude Code。

### 4.5 `age_seconds` 不入文件，由读端计算

读端（Hammerspoon / WebView）每秒计算 `now - updated_at`，用于：
- 列表里相对时间显示（「3 秒前」「2 分钟前」）
- `done` 状态超过 30 秒视为过期
- session 超过 30 分钟不更新则不渲染
- session 超过 1 小时由 hooks 下次写入时 prune 掉（v0.1 已实现）

---

## 5. 菜单栏图标行为

> [v0.2.1 修订] pending 文字位从 `●` 改为 `!`，把"有 N 个在等你"直接说清楚

`hs.menubar` 只支持 `setIcon`（图片）+ `setTitle`（文字），不是自绘 canvas，所以视觉必须拆成「图标位 + 文字位」两部分组合。

### 5.1 三态规则

| 全局优先级 state | 图标位（setIcon） | 文字位（setTitle） | 闪烁/脉冲 |
|---|---|---|---|
| idle（无活跃 session） | SF Symbol `terminal.fill` 或单色 `cc` 图片 | 空 | 无 |
| running（至少一个 running，无 pending） | 同上 | ` N` —— N 为活跃 session 总数 | 无 |
| pending（至少一个 pending） | 同上 | ` N!` —— 末尾追加感叹号，直接表达"有 N 个在等你" | **每 1 秒切换 `!` ↔ 空格**，靠 `hs.timer.doEvery(1, fn)` 重设 title，吸引余光注意 |
| done（最近 30 秒内有完成、且无 pending/running） | 同上 | ` ✓` | 无 |

> **为什么 pending 用 `!` 而不是 `●`**：圆点只是装饰符号，Bella 余光扫过去无法立刻判断含义；`!` 是语义符号，看一眼就知道是「有事在等」。叠加 1Hz 闪烁吸引余光。
> **为什么用文字位做闪烁**：`hs.menubar:setIcon` 只接受 image，不接受动画。重复 `setIcon` 重渲染开销大，且看不出"闪"。改成每秒 `setTitle` 切换末尾 `!`/空格，开销极低、视觉上能感知。

### 5.2 全局优先级计算

复用 v0.1 的 `PRIORITY = {pending:3, done:1, running:2, idle:0}`，取所有 session 的 effective state 里最大优先级作为顶部状态。done 过期（>30s）回落到 idle，由读端动态判定，不依赖 hooks。

### 5.3 计数徽章

`N` = `state in {running, pending, done(<30s)}` 的 session 数。idle session 不计。

---

## 6. 下拉 WebView 面板

### 6.1 尺寸与定位

| 项 | 值 |
|---|---|
| 宽度 | 380px 固定 |
| 高度 | 最小 120px，最大 600px，按内容自适应（CSS `max-height: 600px; overflow-y: auto`） |
| 锚点 | 菜单栏图标正下方，右对齐图标右边缘 |
| 偏移 | 图标下方 6px |
| 边角 | 12px 圆角 |
| 阴影 | `0 24px 60px rgba(0,0,0,0.55)` |

定位实现：从 `hs.menubar:frame()` 拿到图标屏幕坐标，传给 `hs.webview:frame()`。

### 6.2 内容分区（从上到下）

**Header**
- 左：标题 `Claude Code · N sessions`
- 右：三色状态统计 `3 run · 2 wait · 2 done`，每个数字前一个 7×7 状态色 dot

**Session list**
- 每行高度约 56px（含 2 行文字）
- 左 2px 色条（pending 时 1.4s 脉冲，其余静态）
- 中间两行：第一行 `项目名 · label`，第二行状态文字 + cwd 末段
- 右侧：相对时间 + 折叠箭头

**Expanded log（点击 session 后内嵌展开）**
- 展开高度上限 220px
- 上半部：最近 4–6 行 log
- 下半部：根据 state 展示不同 panel
  - `pending` + `pending_permission != null`：permission 卡片（tool 名、命令块、reason，**无按钮**）
  - `pending` + `pending_permission == null`：纯文案「Waiting for your response — switch to your Claude Code window」（无按钮）
  - `running`：spinner + 当前 tool 名（如有，从 log 末行抽）
  - `done`：completed 卡片，仅文字「Completed N 秒前」（无按钮）

**Footer**
- 左：绿点 + `Watching status.json`
- 右：`Open status file` `Quit` 两个 ghost 按钮（pathwatcher 已实时刷新，不需要 Refresh 按钮）

### 6.3 失焦关闭行为

- 用户点 WebView 之外任意区域 → WebView 隐藏
- 实现：`hs.webview:windowCallback` 监听 `focusChange`，失焦时 `:hide()`
- **坑（见第 12 节风险）**：点击菜单栏图标本身既触发"打开 WebView"又触发"WebView 失焦"，需要在 menubar click 回调里判断「当前 WebView 是否可见」做 toggle，而不是无脑 show

### 6.4 JS ↔ Lua 通信

> [v0.2.1 修订] 删除所有跨应用跳转动作，只保留插件自己的事

走 `hs.webview` 的 `navigationCallback` + 自定义 URL scheme（`hammerspoon://` 前缀）。JS 端用 `window.location.href = 'hammerspoon://action?...'` 发起调用，Lua 端拦截 URL、解析参数、执行动作。

v0.2 必须支持的动作（精简后）：

| 动作 | URL | Lua 端做什么 |
|---|---|---|
| 打开 status.json（用户调试用） | `hammerspoon://open-status` | `hs.execute("open ~/.claude-menubar/status.json")` |
| 退出 Hammerspoon | `hammerspoon://quit` | `hs.application.get("Hammerspoon"):kill()` |
| 折叠/展开某 session | 纯前端 JS 即可，不走 Lua | — |

Lua → JS 注入数据：每次 `status.json` 变化时，Lua 读文件、序列化为 JSON 字符串、`webview:evaluateJavaScript("window.renderSessions(" .. json .. ")")`，由前端 `renderSessions` 函数全量重绘。

---

## 7. 交互细节

> [v0.2.1 修订] 此章节按"纯状态显示器"定位重写，删除所有 Open in VS Code 按钮

### 7.1 各状态展开内容

| State | 展开区上半（log） | 展开区下半（action panel） |
|---|---|---|
| running | 最近 4–6 行 log，工具调用行高亮 amber | spinner + 当前 tool 名 + token 数（如能拿到，否则隐藏） |
| pending（permission，v0.2 仅展示） | 最近 4 行 log | permission 卡片（仅展示，无按钮） |
| pending（未来 question 类型，v0.2 暂不实现） | — | — |
| done | 最近 6 行 log | 仅文字 "Completed N 秒前"，无按钮 |
| idle | 不在列表里 | — |

### 7.2 Permission 卡片展示内容

卡片的目标：**让 Bella 一眼读完，决定自己怎么处理**，不引导任何具体操作。

```
┌─────────────────────────────────────┐
│ PERMISSION REQUESTED · bash         │  ← tool 名
│                                     │
│ Claude wants to reinstall deps      │  ← reason（一句话）
│ ┌─────────────────────────────────┐ │
│ │ $ rm -rf node_modules && npm i  │ │  ← command（等宽，可滚动）
│ └─────────────────────────────────┘ │
└─────────────────────────────────────┘
```

`pending_permission == null` 时（v0.2 默认情况）：

```
┌─────────────────────────────────────────────────────┐
│ Waiting for your response —                         │
│ switch to your Claude Code window                   │
└─────────────────────────────────────────────────────┘
```

### 7.3 Log 取自哪里

复用 v0.1 `update_status.py` 已有的 `transcript_path` JSONL 解析逻辑思路，但 v0.2 解析放在 **Lua 端**（避免 hooks 写文件时附带大量 log，状态文件保持瘦）：

- WebView 收到展开 session 请求时，Lua 读取该 session 的 `transcript_path`
- 解析 JSONL，取最后 4–6 条 `type in {user, assistant}` 的消息
- 用户消息前缀 `›`，助手消息前缀 `·`，tool_use 行前缀 `⏵`
- 每行截断 80 字

### 7.4 相对时间刷新

WebView 内 JS 用 `setInterval(updateAges, 5000)` 每 5 秒重算所有 session 的「N 秒前」字样，不需要 Lua 介入。

---

## 8. In scope / Out of scope

### 8.1 In scope（v0.2 必做）

> [v0.2.1 修订] 删除 Open in VS Code 按钮，新增 pending 置顶规则

| 项 | 为什么 |
|---|---|
| Hammerspoon menubar + WebView 整套渲染 | v0.2 的核心 |
| 菜单栏图标三态 + title 闪烁（pending 用 `!`） | 替代 v0.1 emoji 闪烁，做到「不盯屏幕也能感知有几个在等」 |
| WebView 渲染 design handoff 的视觉骨架（无 avatar） | Bella 已拿到完整 CSS，不浪费 |
| Session 行点击展开 + log 解析 | US-B 的判定要求 |
| `pending_permission` 展示（不操作） | US-C 的判定要求 |
| Pending session 永远置顶排序 | US-E 的判定要求 |
| `schema_version` + `pending_permission` 字段预留 | 给 v0.3 直接接菜单栏 allow/deny 留接口 |
| Hammerspoon 自启动登录项 | US-D 的判定要求 |
| `install.sh` 重写为 Hammerspoon 路线 | 用户能一条命令装好 |

### 8.2 Out of scope（v0.2 不做）

| 项 | 为什么 |
|---|---|
| **任何跨应用跳转 / 打开操作（VS Code、Terminal、Claude Desktop 等）** | Bella 可能在多种客户端跑 Claude Code，插件不假设跳转目标。定位为纯状态显示器，不做动作触发器（见 §1.6） |
| Toast banner（菜单关闭时右上角横幅） | Bella 明确不要，避免和系统通知重复 |
| Filter tabs（all/working/waiting/done） | session 数量通常 ≤ 5，靠排序优先级就够看；tab 增加 UI 复杂度 |
| 10 个 bot avatar 角色化 | 视觉锦上添花，不影响功能；用 SF Symbol/dot 代替 |
| 菜单栏内 allow/deny 操作 | 拍板降级到 v0.3。需要 hooks 解析 Notification payload + WebView 回调 Claude Code 协议，工作量大于 v0.2 全部 |
| 多 token 计数 / 进度条 | Claude Code 当前 hook payload 没暴露这些字段 |
| 跨设备 session 同步 | 单机工具，不涉及网络 |
| 声音提醒 | v0.1 已明确不做 |

---

## 9. 验收标准

每条都可手测，开发完一条勾一条：

- [ ] 跑 `./install.sh`，Hammerspoon 被 brew 安装、配置被拷到 `~/.hammerspoon/`、Hammerspoon 进入登录项
- [ ] 重启 Mac 后菜单栏出现 Claude Code 图标
- [ ] 没有任何活跃 session 时，图标显示 idle 态、无文字徽章
- [ ] 在 VS Code 里跑 Claude，触发一次 PreToolUse → 菜单栏 title 出现 ` 1`
- [ ] Claude 问权限 → 菜单栏 title 末尾出现 `!` 并每秒闪烁
- [ ] Claude Stop → 菜单栏 title 出现 ` ✓`，30 秒后回到 idle
- [ ] 点击菜单栏图标 → WebView 在图标正下方弹出，宽 380px
- [ ] WebView 显示所有活跃 session，按 pending > running > done > 最近更新排序
- [ ] **Pending session 永远排在 WebView 列表最顶部，无视更新时间**（手测：30 分钟前的 pending vs 1 分钟前的 running，pending 在前）
- [ ] 点击一行 session → 该行展开，显示最近 4–6 行 log
- [ ] pending session 展开时 → 显示 permission 卡片（`pending_permission` 为 null 时显示纯文案占位，无按钮）
- [ ] 点击 WebView 之外的区域 → WebView 隐藏
- [ ] 再次点击菜单栏图标 → WebView 重新弹出（不卡死）
- [ ] 同时跑 3 个 Claude 会话 → 列表显示 3 行，互不干扰
- [ ] 手动编辑 `~/.claude-menubar/status.json` 把一条 session 改成 pending → 1 秒内菜单栏图标和 WebView 跟着变（pathwatcher 验证）
- [ ] 一条 session 超过 30 分钟没更新 → 从 WebView 列表消失
- [ ] 状态文件被人为损坏（非法 JSON） → Hammerspoon 不崩，菜单栏保持上次有效状态
- [ ] 卸载文档里写的步骤跑完后 → 菜单栏图标消失、`~/.hammerspoon/claude-menubar/` 被删

---

## 10. 开发拆解（里程碑）

按依赖顺序拆 6 个里程碑。每个里程碑独立可验证，开发 agent 一次领一个。

### M1 — Hammerspoon 骨架与菜单栏图标（半天）

**做什么**
- 新建 `hammerspoon/claude-menubar/init.lua`，提供 `start()` / `stop()` 两个函数
- 创建 `hs.menubar.new()`，挂图标和初始 title
- 写一个假的渲染循环：每 5 秒读 `status.json`，用 `print` 打到 Hammerspoon console

**验收**：Hammerspoon reload 后菜单栏出现图标，console 能看到 status.json 内容被打印

### M2 — 文件监听 + 菜单栏 title 三态 + 闪烁（半天）

**做什么**
- 用 `hs.pathwatcher.new(STATUS_FILE, callback)` 监听文件变化
- 实现 effective state 计算（done 过期、TTL 过滤、优先级取最大）
- 用 `hs.timer.doEvery(1, ...)` 切换 title 末尾的 `●` ↔ 空格（仅 pending 态）
- 验证 done 30 秒过期、超过 TTL 的 session 不计入徽章数

**验收**：手动改 status.json，1 秒内菜单栏图标 title 跟着变；pending 时 title 末尾 `●` 闪烁

### M3 — WebView 弹出/隐藏与图标定位（1 天）

**做什么**
- 创建 `hs.webview`，宽 380、高 600，无边框、有阴影
- 点击菜单栏图标 toggle 显示/隐藏；解决"点击图标既打开又触发失焦"的竞态（用 200ms 防抖 + 可见状态标记）
- 失焦自动隐藏
- WebView 显示位置：从 `menubar:frame()` 算出图标 x/y，定位在下方 6px、右对齐图标右边缘

**验收**：图标点一下弹、再点收；点其他地方收；多屏环境下仍然贴在图标下方

### M4 — HTML 渲染 + Lua→JS 注入数据（1 天）

**做什么**
- 在 `~/.hammerspoon/claude-menubar/web/` 下放 `index.html`、`styles.css`、`app.js`
- 把 design handoff 的 `styles.css` 移植过来（移除 React/JSX 特有的、移除 Toast / Tabs / Avatar art 相关样式）
- `app.js` 提供 `window.renderSessions(data)`，纯 DOM 操作渲染 header / list / footer
- Lua 端 `webview:html(loadFile("index.html"))`，每次 status.json 变化时 `evaluateJavaScript("renderSessions(" .. json .. ")")`
- 暂不实现展开

**验收**：WebView 打开后看到所有 session 列表，视觉接近 design handoff 截图（无 avatar、无 tabs、无 toast）

### M5 — 展开行 + log 解析 + permission 展示 + pending 置顶（0.5–1 天）

> [v0.2.1 修订] 删除 Open in VS Code 按钮工作，腾出的时间用于 pending 排序置顶 + 视觉强化

**做什么**
- 前端 JS：点击 session 行 toggle expanded class、收起其他行
- 前端排序：**pending session 永远排在最顶部，其余按 updated_at 倒序**（US-E）
- Lua 端新增「读取某 session transcript 最近 N 行」函数
- 自定义 URL scheme `hammerspoon://expand?sid=...` 让 JS 请求 log，Lua 解析后回注 `window.renderLog(sid, lines)`
- 实现 permission 卡片（`pending_permission != null`，仅展示）和 pending 占位文案（`pending_permission == null`）
- pending 行视觉强化：左侧色条加粗 + 1.4s 脉冲

**验收**：点开任意 session 看到最近 log；pending session 看到 permission 卡片（无按钮）；30 分钟前的 pending 仍排在 1 分钟前的 running 之上

### M6 — 安装脚本重写 + 自启动 + 卸载文档（半天）

**做什么**
- 重写 `install.sh`：装 Hammerspoon（brew cask）、拷 Lua + web 到 `~/.hammerspoon/claude-menubar/`、在 `~/.hammerspoon/init.lua` 末尾追加 `require("claude-menubar").start()`、合并 hooks 到 `~/.claude/settings.json`（这段直接抄 v0.1）、把 Hammerspoon 加进登录项（`osascript` 操作 System Events）
- 写 `uninstall.sh`：删 `~/.hammerspoon/claude-menubar/`、清掉 init.lua 里 require 行、从登录项移除 Hammerspoon、从 `~/.claude/settings.json` 移除 hooks
- 更新 README：安装命令 + Accessibility 授权步骤截图位

**验收**：在干净环境下跑 `./install.sh` 全程一条命令搞定，重启电脑后图标自动出现；`./uninstall.sh` 跑完后无残留

### M7（可选） — `schema_version` 升级与 hooks 微调（半天）

**做什么**
- 修改 `hooks/update_status.py`，写入时加 `schema_version: 2`、新增 `cwd` 字段、保留 `pending_permission: null` 占位
- 读端兼容旧文件（无 `schema_version` 视为 1）

**验收**：旧 status.json 不会让 Hammerspoon 崩；新写入的文件包含 `schema_version`、`cwd`、`pending_permission`

---

## 11. 安装与分发

### 11.1 用户安装步骤

1. `git clone <repo>` → `cd claude-code-menubar` → `./install.sh`
2. 脚本输出一条提示：「请在 系统设置 → 隐私与安全性 → 辅助功能 中允许 Hammerspoon」并贴出 `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"` 让用户一键跳过去
3. 用户授权后，脚本最后一步 `open -a Hammerspoon`，菜单栏出现图标

### 11.2 `install.sh` v0.2 要做的事

按顺序：

1. **检查 Homebrew**，没装就 die 让用户先装
2. **安装 Hammerspoon**：`brew install --cask hammerspoon`（已装则跳过）
3. **创建 `~/.hammerspoon/claude-menubar/`**，拷 `lua/` 和 `web/` 全部资源进去
4. **追加 require 到 `~/.hammerspoon/init.lua`**：
   - 文件不存在则新建
   - 已有 require 行则跳过（用 marker 注释 `-- claude-menubar:require` 防重复）
5. **合并 hooks 到 `~/.claude/settings.json`**：完全抄 v0.1 那段 PYEOF 逻辑，把目标命令改成 `update_status.py`（路径变为 `~/.hammerspoon/claude-menubar/hooks/update_status.py`）
6. **创建空状态文件**：`~/.claude-menubar/status.json`
7. **加 Hammerspoon 到登录项**：`osascript -e 'tell application "System Events" to make login item ...'`
8. **打开 Hammerspoon** 触发 reload；如果是首次启动，提示用户去给 Accessibility 权限
9. 打印「✅ 装好了」+ 卸载提示

### 11.3 卸载

提供 `uninstall.sh`：

1. 删 `~/.hammerspoon/claude-menubar/`
2. 从 `~/.hammerspoon/init.lua` 移除 require 行（用 marker 定位）
3. 从 `~/.claude/settings.json` 移除 hooks 条目（按 command 字符串匹配 `update_status.py` 后删除）
4. 从登录项移除 Hammerspoon（如果用户是装这个之前手动加过的，问一下再删）
5. 不卸载 Hammerspoon 本身（用户可能在用它做别的事），文档里说明

### 11.4 仓库目录结构（v0.2）

```
claude-code-menubar/
├── README.md
├── PRD.md              ← v0.1（保留）
├── PRD_v0.2.md         ← 本文件
├── install.sh          ← 重写
├── uninstall.sh        ← 新增
├── hammerspoon/
│   ├── init-loader.lua ← 写入 ~/.hammerspoon/init.lua 的 require 片段
│   └── claude-menubar/
│       ├── init.lua    ← 入口
│       ├── menubar.lua ← 图标 + title 逻辑
│       ├── webview.lua ← WebView 生命周期
│       ├── transcript.lua ← JSONL 解析
│       └── web/
│           ├── index.html
│           ├── styles.css
│           └── app.js
├── hooks/              ← v0.1 原样保留
│   ├── update_status.py
│   └── clear.sh
└── plugin/             ← v0.1 SwiftBar plugin，可删，但保留作历史参考
```

---

## 12. 风险与未决问题

### R1 — WebView 失焦关闭和点击图标再次打开的竞态（已知，必须解决）

**现象**：用户点菜单栏图标 → WebView 弹出 → WebView 立刻成为焦点 → 用户再点图标想关闭 → 先触发 WebView 失焦回调（隐藏） → 再触发图标点击回调（重新显示） → 结果永远关不掉。

**应对**：在 menubar click 回调和 webview focus-lost 回调之间加 200ms 防抖 + 一个 Lua 全局 `state.webviewVisible` 标记。点击图标时直接读这个标记决定 show/hide，而不是反应式触发。M3 必须解决，验收必看。

### R2 — Hammerspoon Accessibility 授权拒绝

**现象**：用户跑完 install.sh 没去授权 Accessibility，菜单栏图标能出来但 WebView 点不开（macOS 拦截）。

**应对**：
- install.sh 最后明确提示 + 给出系统设置的 deep link
- Hammerspoon `init.lua` 启动时检测 `hs.accessibilityState()`，false 时弹一个 `hs.alert` 提醒
- README 写"看不到 WebView 怎么办"故障排除一节

### R3 — HTML/CSS 资源用内嵌还是外链

**两个选项**：
- **A：外链文件**（`web/index.html` + `styles.css` + `app.js` 三个文件，Lua 读 HTML 后用 file:// 注入）
  - 好处：开发期能直接在浏览器调试
  - 坏处：Hammerspoon WebView 的 file:// 跨资源加载有时不一致
- **B：单文件内嵌**（HTML 里 inline 所有 CSS + JS）
  - 好处：路径 100% 稳定
  - 坏处：调试稍麻烦

**当前倾向**：M4 先用 A，遇到加载问题就切 B；最终发布版本用 B（确定性更高）。决定权在开发 agent，发版前必须决断一次。

### R4 — 多屏 / 外接显示器场景 WebView 定位

未实测。`menubar:frame()` 在外接显示器是否返回正确坐标待验。M3 必须在 Bella 的多屏环境跑一次。

### R5 — Hammerspoon 的 hs.webview 中文字体回退

Hammerspoon 内置 WebKit 在某些 macOS 版本上对 JetBrains Mono 缺失时回退到 Times，会让中文糊。CSS font-stack 必须显式列出 `"PingFang SC", "Helvetica Neue"` 在 mono 字体之后。

### R6 — `update_status.py` 触发 Notification 时无法拿到 permission 详情

v0.3 要做菜单栏内 allow/deny 时，hooks 必须能从 Notification 的 stdin payload 解析出 tool / command / reason。**待补**：需要先采样几次真实 Notification payload 内容，确认 Claude Code 是否把这些字段暴露给 hook。如果不暴露，v0.3 路线要重新设计（可能要走 Claude Code 的官方 prompt-input 机制，而不是 hook）。

### R7 — Status.json 在大型 transcript 下的写入时延

`update_status.py` 读 transcript JSONL 抽 label，对几十 MB 的 JSONL 可能慢。v0.1 没遇到问题但样本小。**待补**：M7 时跑一次最大 transcript 看耗时。
