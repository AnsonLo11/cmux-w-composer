# 09 - Agent Activity Sidebar（只读 AI 操作侧边栏）

> 对应原文：`agentcontext/09-agent-activity-sidebar-20260422-180000.md`
> 时间戳：2026-04-22 ~ 2026-04-23 — 分支 `panel-composer`

## 需求

cmux 窗口右侧添加只读侧边栏，实时展示当前终端面板中 Claude Code agent 的 tool 执行（Bash/Read/Write/Edit/Grep/Glob/Agent）及结果。结构化卡片 UI，非终端镜像。支持多并发 CC session（跟随 focused panel）、session 切换（exit+重启自动切换）、自动展开+手动 override、tool 类型 filter、输出折叠/展开、一键复制、可拖动宽度、bash 语法高亮。

## 技术方案

**数据来源**：监听 CC 的 `~/.claude/projects/<cwd-path-with-dashes>/<sessionId>.jsonl` 文件（方案 C），用 DispatchSource EVFILT_VNODE 增量解析 `tool_use`/`tool_result` JSON 行。排除了 PTY 镜像（方案 A，显示全部内容无法过滤）和 ANSI 解析（方案 B，脆弱依赖 CC 渲染格式）。

**Session 映射**：复用 cmux 现有 claude wrapper hook 基础设施。Wrapper 已生成 `SESSION_ID` + 注入 `SessionStart`/`SessionEnd` hooks。在 CLI hook handler 追加 `set_agent_session`/`clear_agent_session` socket 命令，App 端路由到 `Workspace.agentSessionTracker`。JSONL 路径可确定性推导（cwd path hash + sessionId）。

**侧边栏布局**：Bonsplit 分屏外层 HStack 右侧固定栏，不占 pane 位。10pt 拖动 hit area（对齐左侧 sidebar 标准），宽度 200-600pt 可调。

**显隐逻辑**：`manualOverride ?? hasActiveSession` 状态机。CC session 启动自动展开；Cmd+Shift+A 手动 toggle 优先；切换 panel 重置手动状态。

**渲染**：共享 `ToolCardShell`（左色条、header、chevron、copy 按钮）+ 6 种 tool 专属卡片。Filter chips 水平滚动。输出两层折叠控制（卡片级 chevron + 输出级 "N more lines..." 点击展开 / "▲ Collapse" 收起）。Bash 命令用正则 tokenizer 语法高亮（命令名/flags/字符串/管道/变量 5 种 token）。

## 实际执行

新增 10 文件（`Sources/AgentActivity/` 目录），修改 8 个现有文件（CLI hook、TerminalController、Workspace、WorkspaceContentView、KeyboardShortcutSettings、cmuxApp、AppDelegate、Localizable.xcstrings）+ pbxproj。主要踩坑：`onChange` 不触发初始值（加 `onAppear` 修复）、static property in generic type（提取为外部 enum）、hook 未触发假象（需在 tagged build 内新启动 claude）、DragGesture translation 累积抖动（记录 dragStartWidth 修复）。Build tag `agent-sidebar`。
