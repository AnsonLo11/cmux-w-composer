# 05 - panel-composer 分支完整变更记录

> 对应原文：`agentcontext/05-panel-composer-full-changelog-20260414-214906.md`
> 时间戳：2026-04-14 21:49 — 分支 `panel-composer`（前序 `overlay-composer` 已保存可回退）

## 需求

`overlay-composer` 浮在终端上方会遮挡内容，体验差。这条分支做六件事：

1. **架构重构**：Overlay → Panel，Composer 改为独立面板显示在终端下方，打开时终端自然缩小让出空间。
2. **图片输入系统重写**：截图（⌘⇧4）粘贴失败、保存路径要改成 `~/.claude/image-cache/cmux-composer/`、Composer 中显示内联缩略图而非路径文本、多图发送只有第 1 张生效。
3. **键盘快捷键重映射**：Enter 直接发送（不换行）、Shift+Enter 换行、Cmd+Enter 发送+提交（CC 立即处理）。
4. **自动聚焦修复**：⌘⇧I 打开 Composer 时焦点应自动到输入框。
5. **Up/Down 历史记录**：输入框空白时按 Up/Down 查找之前发送过的 prompt。
6. **UI 调整**：pill 文字截断修复、sidebar 布局、dev banner 文案改为 `Anson's`（蓝色 #08F）。

## 技术方案

**架构**：从 AppKit overlay（`GhosttySurfaceScrollView` 子视图）迁到 SwiftUI 同级面板（`TerminalPanelView` VStack 布局），删除 `setComposerOverlay`/`composerOverlayHostingView` 等约 70 行；保留 `isResponderInsideComposerView()` 静态方法做窗口级焦点守卫；改为 `GhosttyTerminalView.isComposerActive: Bool` 参数透传 + `composerIsActive` 属性。**四个焦点回收路径全部加守卫**：`ensureFocus`、`applyFirstResponderIfNeeded`、`clearSuppressReparentFocus`（reparenting 后恢复，无守卫会被抢）、`reassertTerminalSurfaceFocus`（5+ 处调用，无守卫会重启终端焦点循环）。

**图片**：截图粘贴两层修复——翻转检查顺序（先 `.tiff/.png` 后文本，因 macOS 截图把 file URL 也放剪贴板）+ override `readablePasteboardTypes` 加入图片类型（否则 `isRichText=false` 时 Paste 菜单灰）。`ComposerImageAttachmentCell: NSTextAttachmentCell` 18pt 行内 pill（左 14x14 圆角色块从图采样缩放，右 `[IMAGE #N]` 标签），hover 用 `NSPopover` 显示完整预览（最大 240pt），`NSTrackingArea` + `mouseMoved` 检测。`resolvedTextForSending()` 用 character iterator 遇 `U+FFFC` 替换为 shell-escaped 路径。

**键位**：`doCommandBy(insertNewline:)` 检查 `NSApp.currentEvent?.modifierFlags.contains(.shift)` 分流；新增 `cmuxComposerDidSendAndSubmit` 通知；`sendComposerText(submit:)` submit=true 时追加 `surface.sendInput("\n")`。

## 实际执行

11 个 commit 完成。自动聚焦改了三轮：（1）`hasAppliedInitialFocus` 布尔值首次后不重置，改 `lastFocusedStateID: ObjectIdentifier?` 跟踪 ComposerState identity；（2）`composerIsActive` 守卫只覆盖 2/4 路径，补 `clearSuppressReparentFocus` 和 `reassertTerminalSurfaceFocus`；（3）SwiftUI 渲染顺序时序问题，`TerminalPanelView.onAppear` 立即 `surface.setFocus(false)` + 三重焦点声明（sync + async + 50ms 延迟）。

历史记录：`ComposerState.sendHistory: [String]` 静态数组（最多 50 条）跨 Composer 会话持久，`recordSentText()` 去连续重复，`historyUp/Down` 保存当前未发送文本，`textDidChange` 中 `resetHistoryNavigation()` 退出历史模式，仅在空白或已进入历史模式时拦截 moveUp/moveDown。Pill 文字截断在 `cellSize()` 加 `ceil()` + 2pt 安全余量。
