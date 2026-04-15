# 02 - Composer Input 功能（V1 + V2 概览）

> 对应原文：`agentcontext/02-composer-feature.md`

## 需求

在终端面板底部加一个原生 `NSTextView` 输入框，专门用来组织长 prompt（特别是给 Claude Code 这类 AI agent 用），解决终端原生输入对中文/日文/韩文 IME、鼠标点击定位光标、多行编辑支持差的问题。交互上要求：⌘⇧I 切换显示，⌘Enter 发送（注入终端 stdin 保留换行后清空关闭），Esc 关闭但保留草稿（下次召唤还在）。视觉上位于终端面板底部，1pt 顶线，等宽字体，半透明背景，跟随系统亮/暗外观。语法高亮、Markdown 预览、与具体 AI agent 协议集成不在本期范围。

## 技术方案

新增 `Sources/Composer/{ComposerState.swift, ComposerInputView.swift}`，修改 8 个文件接入。关键设计决策：

- **Overlay 挂在 `GhosttySurfaceScrollView`（AppKit portal 层）而不是 SwiftUI 容器层**——CLAUDE.md 的 layering contract 要求 terminal portal 在 split/workspace 重布局时会盖住 SwiftUI 层，overlay 必须跟它在一起。
- **用 `NSTextView` 不用 SwiftUI `TextEditor`**——IME 完整、底层可控、能精确拦截 ⌘Enter（在 `NSScrollView.performKeyEquivalent` 拦截，因为 `doCommandBy` 收不到带 Cmd 的组合键）。
- **Send/Dismiss 用 `NotificationCenter`**——overlay 闭包对 `TerminalPanel` 弱引用困难，用通知优雅解耦。
- **`sendComposerText()` 是唯一调 `surface.sendInput()` 的地方**——首版双重发送被 code review 抓出。
- **草稿放 `TerminalPanel.savedComposerDraft`**，hide 时拷一份，召唤时灌回，发送后清空，不持久化到磁盘。

V2 增量：斜杠命令补全（多源聚合内置/插件 SKILL.md/用户/项目命令的 `SlashCommandRegistry`）+ 图片输入（粘贴/拖拽/+ 按钮三种入口，复用 `GhosttyPasteboardHelper` 与 `TerminalImageTransferPlanner`）。

## 实际执行

最大的坑是焦点。第一版打字 "what?" 出现 composer 里 `ddydww?` + 终端里 `WHATW?`——first responder 在两边震荡。根因是 cmux 终端有四条激进焦点回收链路（`ensureFocus`、`applyFirstResponderIfNeeded`、`reassertTerminalSurfaceFocus`、`TerminalPanel.focus`），cmux 现成的 search overlay (⌘F) 已经处理过同样问题。修复方案直接 mirror search overlay 的整套模式：三个新 helper（`isComposerOverlayOrDescendant`、`mountedComposerTextView`、`restoreComposerFocus`）、两条焦点路径加 guard、跨 surface 守卫防止其他面板的 reclaim 抢这个面板焦点、mount 时立即 `surfaceView.terminalSurface?.setFocus(false)` + `makeFirstResponder(textView)`、TextView `becomeFirstResponder()` 反向通知 surface 失焦关掉 Ghostty 内部光标循环、用 `Coordinator.hasAppliedInitialFocus` 标志只在首次显示时抢一次焦点。
