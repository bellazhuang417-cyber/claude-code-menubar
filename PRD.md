# Claude Code Menubar — PRD

## 1. 背景与问题

Bella 在 VS Code 里重度使用 Claude Code，当前通过 macOS 系统通知（右上角横幅）接收 Claude 的状态事件。存在两个问题：

1. **易错过**：系统通知只弹一次就消失，没盯屏幕时会漏掉
2. **无静态状态**：无法一眼看到"现在是否有待确认的权限请求"

实际场景里最常见的两类信号是：
- **权限请求**：Claude 需要 Bella say yes/no 才能继续（否则阻塞）
- **任务完成**：Claude 回答完了，可以回来看结果

## 2. 目标

在 macOS 菜单栏（屏幕最顶部）常驻一个图标，根据 Claude Code 当前状态**持续显示 + 闪烁**，让 Bella 不盯屏幕也能感知 Claude 的进度。

**非目标**：
- 不做声音提醒（Bella 明确要求静默）
- 不替代系统通知，可并存
- 不做跨设备同步

## 3. 用户故事

- **US-1** 作为 Bella，我在写文档时，Claude 在另一个 VS Code 窗口跑任务，我希望**一抬眼看菜单栏**就知道它是不是在等我确认
- **US-2** 作为 Bella，当 Claude 需要我批准权限时，我希望菜单栏图标**闪烁**吸引注意，直到我点回 VS Code 处理
- **US-3** 作为 Bella，当 Claude 跑完任务，我希望图标短暂变"完成"态，之后自动回到 idle，不留残影
- **US-4** 作为开源用户，我希望 clone 仓库后**一条命令**就装好全套（SwiftBar + 插件 + hooks）

## 4. 功能设计

### 4.1 状态机

| 状态 | 触发事件 | 图标 | 行为 |
|------|---------|------|------|
| `idle` | 默认 / 超时回落 | 💤 | 静态，Claude 睡觉中 |
| `running` | PreToolUse 触发 | 🤖 ↔ ⚙️ | 每 1s 交替（机器人转齿轮） |
| `pending` | Notification 触发（需要确认） | 👀 ↔ 🙈 | **每 1s 闪烁**（偷看/捂眼，吸引注意） |
| `done` | Stop 触发（任务完成） | 🎉 | 静态显示 **30 秒**后自动回 idle |

**冲突规则**：`pending` > `done` > `running` > `idle`（优先级高的覆盖低的）

**"比较活"的取舍**：Claude 每调一次工具都触发 running 事件，若状态跟随切换会过于频繁。设计上让 running 一旦点亮就保持，直到 Stop 事件才切换，避免菜单栏频繁跳变。

### 4.2 组件架构

```
Claude Code
    ↓ (fires hook event)
Hook 脚本 (write_status.sh)
    ↓ (writes JSON)
~/.claude-menubar/status.json
    ↑ (reads every 1s)
SwiftBar 插件 (claude.1s.py)
    ↓ (stdout)
macOS 菜单栏图标
```

### 4.3 状态文件格式（v2，按 session 聚合）

`~/.claude-menubar/status.json`

```json
{
  "sessions": {
    "6867152e-9055-46e6-838f-33968015e76c": {
      "state": "pending",
      "project": "AI cowork space",
      "label": "帮我加一个菜单栏通知…",
      "updated_at": 1745840000,
      "transcript_path": "/Users/bella/.claude/projects/.../xxx.jsonl"
    },
    "89a51fec-a77f-414a-9746-b54db179cb3b": {
      "state": "running",
      "project": "play-product-schema",
      "label": "Content Health Check V7 迭代…",
      "updated_at": 1745840010,
      "transcript_path": "..."
    }
  }
}
```

- `sessions`: 按 Claude Code 的 `session_id` 聚合，同一会话重复触发 hook 会 upsert 同一条
- `label`: 从 `transcript_path` JSONL 中抽取首条**用户文本消息**的前 40 字（跳过 `@文件引用`、`<tag>`、skill 注入的 "Base directory for..." 等系统消息）
- 过期策略：单个 session 超过 `SESSION_LIST_TTL=30min` 未更新，插件渲染时隐藏；超过 1 小时则从文件中物理删除
- 并发写保护：`update_status.py` 用 `fcntl.LOCK_EX` 文件锁，避免多 session 同时触发 hook 时互相覆盖

### 4.4 菜单栏交互（v2）

- **顶部图标**：展示全局优先级最高的 state（pending > running > done > idle），1s 闪烁
- **下拉面板**：
  - 标题行：`Claude Code · N 个会话`
  - 每个 session 两行：状态 emoji + label / 状态中文 + 项目名 + 相对时间
  - `Clear all` 菜单项：清空所有 session
  - `Open status file`：打开状态 JSON 调试
  - `Refresh now`：手动刷新

### 4.4 菜单栏交互

- **顶部图标**：按状态显示 SF Symbol
- **点击展开**：
  - 当前状态 + 项目名 + 更新时间（相对时间，如"3 秒前"）
  - `Clear` 菜单项：手动清除状态回到 idle
  - `Open status file` 菜单项：调试用
  - `About` 菜单项：跳到 GitHub

### 4.5 闪烁实现

SwiftBar 插件文件名 `claude.1s.py` → 每 1 秒执行一次。
脚本内根据 `time.time() % 2` 判断输出完整图标或空白，实现 1s 闪烁节奏。

## 5. 技术方案

| 组件 | 选型 | 理由 |
|------|------|------|
| 菜单栏宿主 | **SwiftBar** | 开源活跃、支持 SF Symbol、插件用任意脚本语言 |
| 插件脚本 | **Python 3**（macOS 自带） | Bella 偏好 Python；无需额外依赖 |
| Hook 脚本 | **Bash** | Claude Code hooks 原生支持；无解释器依赖 |
| 状态存储 | **JSON 文件**（~/.claude-menubar/） | 简单、无锁冲突（单写多读）、易调试 |
| 图标样式 | **SF Symbol**（:symbol_name: 语法） | Mac 原生、支持 dark/light mode 自适应 |

## 6. 安装流程

用户执行一条命令：

```bash
./install.sh
```

脚本做的事：
1. 检查 Homebrew，没装则提示用户安装
2. `brew install --cask swiftbar`（已装则跳过）
3. 复制 `plugin/claude.1s.py` 到 SwiftBar 插件目录
4. 合并 hooks 配置到 `~/.claude/settings.json`（保留用户已有配置）
5. 创建 `~/.claude-menubar/status.json` 初始文件
6. 启动 SwiftBar（若未启动）
7. 输出"✅ 装好了，去 VS Code 里跑一下 Claude 试试"

## 7. 验收标准

- [ ] 跑 `./install.sh` 后，菜单栏出现 ◌ 图标
- [ ] Claude 询问权限时，图标 1s 闪烁 ⚠︎
- [ ] 点 Yes/No 回到 idle 后，图标停止闪烁（回到 ◌ 或短暂 ✓）
- [ ] Claude 任务完成时，图标变 ✓ 并在 30s 后回到 ◌
- [ ] 同时跑多个 Claude 会话，以最新状态为准（不崩）
- [ ] 不发声音、不弹出多余通知

## 8. 风险与边界

- **SwiftBar 未运行时**：状态文件会持续更新，但用户看不到。安装脚本会 `open -a SwiftBar` 启动，长期方案靠用户自行设为登录项
- **多会话并发**：当前设计用"最新状态覆盖"，不区分会话。初版不解决多并发区分（后续版本可扩展 `sessions` 数组）
- **done 状态过期判断**：由插件每秒读文件时判断 `now - updated_at > 30` 回落到 idle，无需额外定时器

## 9. 开源发布计划

- **License**: MIT
- **仓库名**: `claude-code-menubar`
- **README**: 含 GIF 演示 + 安装命令 + 架构图
- **目标用户**：所有在 macOS 用 Claude Code 的人
