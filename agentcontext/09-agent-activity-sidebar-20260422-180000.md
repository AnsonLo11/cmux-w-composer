# 09 - Agent Activity Sidebar（只读 AI 操作侧边栏）

> 时间戳：2026-04-22 ~ 2026-04-23 — 分支 `panel-composer`

## 需求

在 cmux 窗口右侧添加一个**只读侧边栏**，实时展示当前终端面板中 Claude Code agent 的 tool 执行（Bash 命令、文件读写、搜索等）及其结果。用户不需要在终端输出中翻找 agent 做了什么——侧边栏以结构化卡片的形式清晰呈现。

核心要求：
1. 只显示 agent 的 tool 执行和结果，不是终端的完整镜像
2. 支持多个并发 CC session——侧边栏跟随当前 focused panel
3. 同一 panel 中 exit + 重启 CC 时自动切换到新 session
4. 检测到 CC session 时自动展开，支持手动 override
5. 所有 tool 类型均显示，支持 filter
6. 卡片可折叠/展开，支持一键复制命令
7. 侧边栏宽度可拖动调节

## 决策路径

### 数据来源方案选型

评估了三种方案：

| 方案 | 描述 | 结论 |
|------|------|------|
| A - PTY 流镜像 | 在 PTY master fd 层面 tee 输出到第二个 Ghostty surface | **排除**：需修改 Ghostty 子模块；显示全部内容无法过滤；用户只想看 tool 执行 |
| B - 解析终端 ANSI 输出 | 从终端输出流中正则匹配 CC 的 tool 执行格式 | **排除**：极度脆弱，依赖 CC 的 TUI 渲染格式（非 stable API），ANSI 解析复杂 |
| C - 结构化 conversation JSONL | 监听 CC 的 `~/.claude/projects/<hash>/<sessionId>.jsonl` 文件 | **选中**：数据最干净（tool_use/tool_result 遵循 Anthropic API spec），不依赖终端渲染格式 |

关键发现：CC 的项目目录 "hash" 实际只是路径中 `/` 替换为 `-`（如 `/Users/ansonlo/project/cmux` → `-Users-ansonlo-project-cmux`），可确定性推导。

### Session 映射方案

评估了三种映射方案：

| 方案 | 描述 | 结论 |
|------|------|------|
| 自动检测（进程树） | kqueue 监听 shell 子进程 fork/exit，lsof 查 conversation 文件 | 可行但复杂 |
| 纯文件系统监控 | 监听 `~/.claude/sessions/` 目录变化，按 cwd 匹配 | 多 agent 同 cwd 时无法区分 |
| 复用 cmux 现有 hook | cmux wrapper 已生成 session ID + 注入 hooks | **选中**：零新增检测机制 |

**关键发现**：cmux 的 claude wrapper（`Contents/Resources/bin/claude`）已经：
- 用 `uuidgen` 生成 `SESSION_ID` 并传给 CC `--session-id`
- 用 `exec` 替换自身（claude 就是 shell 的直接子进程，无中间进程）
- 注入 `SessionStart`/`SessionEnd` hooks 回调到 cmux socket
- 环境变量 `CMUX_SURFACE_ID`/`CMUX_WORKSPACE_ID` 已经在终端中

因此只需在现有 hook 回调中追加一个 `set_agent_session` socket 命令即可。

### 渲染方案

- 选择**结构化卡片**（非终端风格、非纯日志流）
- 每种 tool 有专属卡片样式（Bash 显示命令+输出，Edit 显示 diff，Grep 显示匹配数等）
- 水平 filter chips 按 tool 类型过滤

### 侧边栏布局

- 选择**固定右侧栏**（在 Bonsplit 分屏外层），不占 pane 位
- 通过 `WorkspaceContentView` 的 HStack 实现

### 显隐逻辑

- 自动：有活跃 CC session 时自动展开
- 手动优先：用户 Cmd+Shift+A 手动开/关，优先于自动逻辑
- 切换 panel 时 reset 手动状态，重新按自动逻辑决定

## 技术方案

### 架构

```
cmux wrapper 启动 claude → 注入 --session-id UUID
  → SessionStart hook → cmux CLI → set_agent_session socket command
  → TerminalController → Workspace.agentSessionTracker.registerSession()
  → 计算 JSONL 路径 → ConversationLogWatcher (DispatchSource EVFILT_VNODE)
  → 增量解析 JSONL → tool_use/tool_result → ToolEvent
  → AgentActivityStore (@Published) → AgentActivitySidebar (SwiftUI 卡片列表)
```

### 核心模块

| 模块 | 文件 | 职责 |
|------|------|------|
| `ToolEvent` | `Sources/AgentActivity/ToolEvent.swift` | 数据模型：ToolType（7种+Other）、ToolInput（per-tool 解析）、ToolResult、ToolEvent |
| `ConversationLogWatcher` | `Sources/AgentActivity/ConversationLogWatcher.swift` | DispatchSource 监听 JSONL 文件写入，增量读取 + 逐行 JSON 解析，文件不存在时监听目录等待创建 |
| `AgentActivityStore` | `Sources/AgentActivity/AgentActivityStore.swift` | Per-session 事件存储，@Published events，filter 状态，session ended 标记 |
| `AgentSessionTracker` | `Sources/AgentActivity/AgentSessionTracker.swift` | Panel→session 映射协调器，watcher 生命周期管理，focus tracking，sidebar 显隐状态机 |
| `AgentActivitySidebar` | `Sources/AgentActivity/AgentActivitySidebar.swift` | 侧边栏容器：header、filter chips、scrollable 卡片列表、空状态、session ended |
| `ToolCardShell` | `Sources/AgentActivity/Cards/ToolCardShell.swift` | 共享卡片外壳：左色条、header（icon/timestamp/duration/copy）、chevron 展开/折叠 |
| `BashCardView` | `Sources/AgentActivity/Cards/BashCardView.swift` | Bash 命令卡片：语法高亮命令 + 可折叠输出 + error banner |
| `FileOpCardView` | `Sources/AgentActivity/Cards/FileOpCardView.swift` | Read/Write/Edit 卡片：文件路径 + inline diff |
| `SearchCardView` | `Sources/AgentActivity/Cards/SearchCardView.swift` | Grep/Glob 卡片：pattern + 结果数 |
| `AgentCardView` | `Sources/AgentActivity/Cards/AgentCardView.swift` | 子 agent 卡片：description + prompt |

### Socket 命令扩展

CLI 端（`CLI/cmux.swift`）：
- `session-start` handler 追加 `set_agent_session <sessionId> --surface=<surfaceId> --tab=<workspaceId> --cwd=<path>`
- `session-end` handler 追加 `clear_agent_session --surface=<surfaceId> --tab=<workspaceId>`

App 端（`Sources/TerminalController.swift`）：
- 新增 `setAgentSession` / `clearAgentSession` 命令处理，路由到 `Workspace.agentSessionTracker`

### JSONL 解析细节

tool_use 行结构（type: "assistant"）：
```json
{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_xxx", "name": "Bash", "input": {"command": "ls"}}]}, "timestamp": "...", "sessionId": "..."}
```

tool_result 行结构（type: "user"）：
```json
{"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_xxx", "content": "..."}]}, "toolUseResult": {"durationMs": 350}, "sessionId": "..."}
```

配对：通过 `tool_use.id` ↔ `tool_result.tool_use_id` 关联。

### Bash 语法高亮

使用简单的正则 tokenizer（`BashHighlightedText`），通过 `AttributedString` 实现：
- 命令名（`^` 或 `|`/`;`/`&&` 后的第一个 word）→ 白色高亮
- Flags `--flag` `-f` → 浅蓝色
- 字符串 `"..."` `'...'` → 绿色
- 管道/重定向 `| > && ;` → 橙色
- 变量 `$VAR` `${VAR}` → 紫色

### 可拖动侧边栏宽度

`AgentSidebarResizeHandle`：
- 10pt hit area（6pt sidebar 侧 + 4pt 终端侧），和左侧 sidebar 的 `SidebarResizeInteraction` 对齐
- 视觉 1pt 分隔线，拖动时 2pt + 更亮
- 宽度范围 200pt ~ 600pt，默认 320pt
- 基于 `dragStartWidth` 计算避免抖动

### 输出折叠/展开

两层控制：
- **卡片级**：左上角 chevron ▶/▼ 按钮控制整张卡片的展开
- **输出级**：点击 "N more lines..." 文字展开输出，展开后底部显示 "▲ Collapse" 按钮收起
- 两层独立：chevron 展开会连带展开输出，但输出可以单独收起

## 实际执行

### 新增文件（10 个）

```
Sources/AgentActivity/
├── ToolEvent.swift
├── ConversationLogWatcher.swift
├── AgentActivityStore.swift
├── AgentSessionTracker.swift
├── AgentActivitySidebar.swift
└── Cards/
    ├── ToolCardShell.swift
    ├── BashCardView.swift
    ├── FileOpCardView.swift
    ├── SearchCardView.swift
    └── AgentCardView.swift
```

### 修改文件（8 个）

| 文件 | 修改内容 |
|------|---------|
| `CLI/cmux.swift` | session-start/end 追加 set/clear_agent_session 命令 |
| `Sources/TerminalController.swift` | 新增 setAgentSession/clearAgentSession 命令处理 |
| `Sources/Workspace.swift` | 添加 `agentSessionTracker` 属性 |
| `Sources/WorkspaceContentView.swift` | HStack 布局加入侧边栏 + focus tracking + resize handle |
| `Sources/KeyboardShortcutSettings.swift` | 注册 `.toggleAgentSidebar`（Cmd+Shift+A） |
| `Sources/cmuxApp.swift` | View 菜单加入 Toggle Agent Sidebar |
| `Sources/AppDelegate.swift` | 添加 `toggleAgentSidebarInActiveMainWindow()` |
| `Resources/Localizable.xcstrings` | 10 个新 localized strings（en + ja） |
| `GhosttyTabs.xcodeproj/project.pbxproj` | 注册 10 个新源文件 |

### 文档

- 设计 spec：`docs/superpowers/specs/2026-04-22-agent-activity-sidebar-design.md`
- 实现计划：`docs/superpowers/plans/2026-04-22-agent-activity-sidebar.md`

### 踩坑记录

1. **初始 focus 未设置**：`onChange(of: workspace.focusedPanelId)` 只在值变化时触发，首次渲染不触发。追加 `onAppear` 设置初始 focused surface 修复。
2. **Surface ID vs Panel ID 混淆**：`CMUX_SURFACE_ID`（hook 环境变量）和 `workspace.focusedPanelId` 看似不同，实际调查发现 `TerminalPanel.init` 里 `self.id = surface.id`，两者是同一个 UUID。虚惊一场。
3. **Static stored property in generic type**：`ToolCardShell` 是泛型 struct，不能有 `static let` 属性。提取为外部 `private enum ToolCardTimestampFormatter` 绕过。
4. **Hook 未触发的假象**：测试时用的 CC session 是在旧版 app 里启动的，hooks 自然不会发送新的 `set_agent_session` 命令。需要在 tagged build 的 app 里**新启动** claude 才能触发。
5. **DragGesture translation 累积**：`value.translation` 是累积值而非增量，直接用 `width - translation` 会导致抖动。改为记录 `dragStartWidth` 基于起始值计算。

### Build tag

`agent-sidebar`，产出 `cmux DEV agent-sidebar.app`。
