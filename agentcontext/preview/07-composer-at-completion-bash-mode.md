# 07 - Composer `@` 文件补全 + Bash 模式

> 对应原文：`agentcontext/07-composer-at-completion-bash-mode-20260415-172317.md`
> 时间戳：2026-04-15 17:23 — 分支 `panel-composer`

## 需求

四条需求打包：（1）`/` 弹窗要**左对齐** composer 卡片（原本居中偏右）；（2）弹窗鼠标悬停顶部/底部时列表会像拉滑条一样**飞滚**，要减速或禁用；（3）输入 `空格+@` 触发**文件补全**，列出终端 cwd 下的文件，弹窗样式复用 `/` 的；（4）空输入框首字敲 `!` 或中文 `！` 进入 **bash 模式**——深色 #0D1117 渐变 + 噪点、等宽字体、左侧 `❯` prompt、块状呼吸光标、cyan glow 边框、**独立** bash 历史（↑↓ 不和聊天混）、Tab 文件补全、退出平滑过渡。澄清后三个关键定论：Q1 指鼠标不是文本光标（弹窗内部 bug）、Q2 `@` 的 cwd 跟随终端进程当前 cwd、Q3 bash Enter 发送 **英文** `!command` 给 CC 处理。范围选 P1+P2+P3，暂缓真 bash 补全、独立 shell 执行、终端 surface 滚动。

## 技术方案

**根因定位**（悬停飞滚）：`SlashCompletionView` 里 `.onHover { selectedIndex = index }` + `onChange(selectedIndex) { proxy.scrollTo(newIndex, anchor: .center) }` 形成反馈环——悬停顶部 item → 选中它 → 滚到中央 → 列表下移 → 鼠标下方新 item 冒出 → 再选中 → 再滚。正中央 item 本来就在中央所以静止。修复：去掉 `.onHover` 选择绑定（mouse 只点击不改选中）+ `anchor: nil`（仅在目标不可见时滚）。

**前置重构**：抽 `CompletionItem` 协议 + `CompletionTagStyle`，把 `SlashCompletionView` 改名并泛化成 `CompletionPopupView<Item: CompletionItem>`；`SlashCommand` 通过 extension 实现协议。这样 `@` 和 Tab 文件补全共用同一套弹窗容器。

**`@` 补全**：纯逻辑 `FileTokenDetector.detectAtToken(in:cursorOffset:)`（UTF-16/NSRange-based，往回走遇 whitespace 停遇 `@` 且前位是 whitespace/start 命中）+ `FileCompletionProvider.list(cwd:filter:)`（跳 `.git`/`node_modules`，目录排前，200 封顶）+ `FileEntry: CompletionItem`。cwd 链路：发现 `TerminalPanel.directory` 已 `@Published` 但 `updateDirectory` 从没被调，一行在 `Workspace.updatePanelDirectory` 追加 `terminalPanel(for: panelId)?.updateDirectory(trimmed)` 打通 OSC-7 → panel 的观察链。

**Bash 模式**：`ComposerState.bashMode: Bool` + `static func shouldEnterBashMode(text:)`（接受 `!`/`！`）+ 独立 `bashHistory` + `historyUp/Down` 按 bashMode 分流 + `payloadForSending()`（bashMode 时加**英文** `!` 前缀）。发送路径 `TerminalPanel.sendComposerText` 改 3 处。视觉在 composer card 的 background/overlay/shadow 三处按 bashMode 分叉，整个 card 包在 `.animation(.easeInOut(0.22), value: bashMode)` 里联动；NSTextView 的主题切换走 `NSAnimationContext` 200ms 手动同步。块光标 override `drawInsertionPoint`，忽略系统 `turnedOn`，自己用 `Timer(interval: 1/30)` + `sin(bashBreathPhase) * 0.5 + 0.5` 驱动 0.35–1.0 透明度呼吸。IME 守卫 `hasMarkedText()` 挡组合态。Tab 补全：新增 `detectWordBeforeCursor`，word 当 filter 跑同一个 `FileCompletionProvider`，弹 `CompletionPopupView<FileEntry>`，插入路径和 `@` 共用。

## 实际执行

**10 commit、28 个新单测全绿**（`FileCompletionTests` 18 + `BashModeTests` 10）。按顺序：agentcontext 同步 → 会话前置（focus-fix + preview docs）→ 重构 CompletionPopupView → 左对齐 → hover invariant 注释 → `@` 补全 → bashMode 状态机 → 视觉主题 → 块光标 → Tab 补全。

踩了 7 个坑：（1）新 Array 扩展 `subscript(safe:)` 和 ComposerInputView 尾部私有扩展重定义冲突，删后者保留引用注释；（2）pbxproj UUID `A500C005`/`A500C014` 和 `slash-commands.json` 撞车导致 `FileCompletion.o` 编译缺失，换 `A500C006`/`A500C015` 修复——教训是加 UUID 前必 `grep` 空槽；（3）hover 修复被任务 1 重构顺手吃掉，任务 3 只剩注释提交，两边 commit message 互相引用补救；（4）codesign 在本地不签名构建时报 `cmuxTests.xctest not signed`，过滤 SwiftCompile error 行即可判断真实编译状态；（5）`TerminalPanel.directory` 一直空字符串因 updateDirectory 没人调，查出真源在 `workspace.panelDirectories` 后一行补桥；（6）SwiftUI 动画不传递到 NSTextView，用 NSAnimationContext 自己做 200ms 淡入和 SwiftUI 220ms 错 20ms，感知上同步；（7）块光标初版忘 `hasMarkedText()` 守卫，中文 IME 选字时块光标和组合候选高亮叠一起，补 guard 后走 super 正常。

Build tag `composer-bash` 产出 `cmux DEV composer-bash.app`。纯视觉部分（dark theme、glow、block cursor、平滑过渡）在 commit message 里显式声明「无实用单测」，按 CLAUDE.md 测试质量政策跳过而非造假测试。
