# Panel-based Composer: 完整变更记录

> 时间戳：2026-04-14 21:49
> 分支：`panel-composer`（基于 `main`）
> 前序分支：`overlay-composer`（旧 overlay 实现，已保存可回退）
> 前序记录：`03-*`（斜杠补全+图片输入初版）、`04-*`（UI 打磨）已记录 overlay 版本的需求和方案，本文件仅记录 panel-composer 分支上的增量。

---

## 一、架构重构：Overlay → Panel

### 需求
Composer 浮在终端上方，遮挡内容。改为独立面板，显示在终端下方，打开时终端缩小。

### 方案
- 从 AppKit overlay（`GhosttySurfaceScrollView` 子视图）迁移到 SwiftUI 同级面板（`TerminalPanelView` 的 VStack 布局）
- 终端自然缩小让出空间
- 删除 overlay 挂载代码（`setComposerOverlay`、`composerOverlayHostingView` 等 ~70 行）
- 保留 `isResponderInsideComposerView()` 静态方法用于窗口级焦点守卫

### 焦点保护改造
Overlay 版本用 `composerOverlayHostingView != nil` 检测 Composer 存在。Panel 版本改为：
- `GhosttyTerminalView.isComposerActive: Bool` 参数从 `TerminalPanelView` 传入
- `GhosttySurfaceScrollView.composerIsActive` 属性在 `updateNSView` 中设置
- 四个焦点回收路径全部加守卫：

| 路径 | 作用 |
|------|------|
| `ensureFocus` | 窗口/tab 切换时恢复焦点 |
| `applyFirstResponderIfNeeded` | 延迟焦点应用 |
| `clearSuppressReparentFocus` | view reparenting 后恢复焦点 |
| `reassertTerminalSurfaceFocus` | 5+ 处调用，`setFocus(true)` 重启终端焦点循环 |

### 涉及文件
```
Sources/Panels/TerminalPanelView.swift    — VStack 布局 + ComposerInputView 渲染 + .onAppear setFocus(false)
Sources/GhosttyTerminalView.swift         — 通知名、isComposerActive 参数、composerIsActive 属性、四处焦点守卫、isResponderInsideComposerView 静态方法
Sources/Composer/ComposerInputView.swift  — 删除 Spacer()、默认高度 120→80pt
```

### Git
```
298285db Panel-based Composer with focus fix
```

---

## 二、图片输入系统重写

### 需求
1. 截图（Cmd+Shift+4）粘贴失败 — Paste 菜单灰掉
2. 保存到 `~/.claude/image-cache/cmux-composer/` 而非系统临时目录
3. Composer 中显示内联缩略图而非文件路径
4. 多图发送只有第 1 张生效

### 方案与修复

#### 截图粘贴修复（两层问题）
- **问题 1**：`paste()` 中先检查 `stringContents()`，macOS 截图在剪贴板放了 file URL → 被当作文本处理
- **修复**：翻转检查顺序，先检查 `.tiff/.png` 图片数据
- **问题 2**：`NSTextView` 在 `isRichText=false` 时 `readablePasteboardTypes` 不含图片类型 → Paste 菜单灰掉
- **修复**：override `readablePasteboardTypes` 加入 `.tiff` 和 `.png`

#### 图片保存
- `ComposerState.saveImageFromPasteboard()` → 保存到 `~/.claude/image-cache/cmux-composer/image_N.png`
- 先调 `GhosttyPasteboardHelper.saveImageFileURLIfNeeded()` 保存到临时目录，再 copy 到目标目录
- Fallback：直接从 NSPasteboard 读 NSImage → TIFF → PNG

#### 内联缩略图
- `ComposerImageAttachmentCell: NSTextAttachmentCell` — 18pt 行内 pill
- 左侧：14x14 圆角色块（从图片采样缩放）
- 右侧：`[IMAGE #N]` 标签文字
- Hover：`NSPopover` 显示完整预览图（最大 240pt）
- `ComposerNSTextView` 添加 `NSTrackingArea` + `mouseMoved` 检测 attachment hover

#### 发送时解析
- `ComposerState.resolvedTextForSending()` 逐字符遍历文本
- 遇到 `U+FFFC`（attachment 字符）→ 从 `imageInsertionOrder` 取对应 URL → 替换为 shell-escaped 路径
- 同时兼容 `[IMAGE #N]` 文本标记（fallback 路径）

#### 多图修复
- 旧代码用 `result.range(of: attachmentChar)` 循环替换，逻辑正确但依赖 `imageInsertionOrder` 完整性
- 新代码改为 character iterator + index iterator，更鲁棒

### 涉及文件
```
Sources/Composer/ComposerState.swift      — attachedImages、imageInsertionOrder、saveImageFromPasteboard、resolvedTextForSending、addImage
Sources/Composer/ComposerInputView.swift  — paste() 翻转、readablePasteboardTypes、ComposerImageAttachmentCell、hover popover
Sources/Panels/TerminalPanel.swift        — sendComposerText 调用 resolvedTextForSending
```

### Git
```
475cf8b1 Image markers: fix screenshot paste, [IMAGE #N] display, resolve on send
a08d54e4 Inline thumbnail attachments for pasted/dropped images
96fc32a6 Fix Paste grayed out for images: declare readable pasteboard types
8abaddd0 Inline pill thumbnails with hover preview + change dev banner to anson's
064c8b95 Fix pill truncation, multi-image send, sidebar layout
```

---

## 三、键盘快捷键重映射

### 需求
- Enter 直接发送（不是换行）
- Shift+Enter 换行
- Cmd+Enter 发送 + 提交（CC 立即处理）

### 方案
- `doCommandBy(insertNewline:)` 中检查 `NSApp.currentEvent?.modifierFlags.contains(.shift)`
- Shift → 交给 NSTextView 默认行为（换行）
- 无修饰 → 触发 `onSend`（发送到终端，不追加 `\n`）
- `ComposerScrollView.performKeyEquivalent` Cmd+Enter → `onSendAndSubmit`
- `TerminalPanel.sendComposerText(submit: Bool)` — submit=true 时追加 `surface.sendInput("\n")`
- 新增通知 `cmuxComposerDidSendAndSubmit`
- 发送按钮改为触发 send+submit（和 Cmd+Enter 一致）

### 涉及文件
```
Sources/Composer/ComposerInputView.swift  — doCommandBy、onSendAndSubmit 回调、ComposerScrollView
Sources/Panels/TerminalPanel.swift        — sendComposerText(submit:)
Sources/Panels/TerminalPanelView.swift    — onSendAndSubmit 闭包
Sources/GhosttyTerminalView.swift         — cmuxComposerDidSendAndSubmit 通知名
Sources/TabManager.swift                  — 新通知观察者
```

### Git
```
966a6517 Remap keyboard shortcuts: Enter=send, Shift+Enter=newline, Cmd+Enter=send+submit
```

---

## 四、自动聚焦修复

### 需求
Cmd+Shift+I 打开 Composer 时焦点应自动到输入框。

### 问题与修复历程

1. **第一次有效，后续失败** — `hasAppliedInitialFocus` 布尔值首次设 `true` 后不重置，SwiftUI 复用 Coordinator
   - 修复：改用 `lastFocusedStateID: ObjectIdentifier?`，每次 Composer 创建新 ComposerState（新 identity）时重新触发

2. **焦点到了又被抢走** — `composerIsActive` 守卫只在 2/4 个焦点路径上
   - `clearSuppressReparentFocus`：SwiftUI 布局变化触发 view reparenting → 焦点回收（无守卫）
   - `reassertTerminalSurfaceFocus`：被 5+ 处调用 → `setFocus(true)` 重启终端焦点循环（无守卫）
   - 修复：全部 4 个路径加 `composerIsActive` + `isResponderInsideComposerView` 双重守卫

3. **时序问题** — SwiftUI 渲染顺序不确定，`composerIsActive` 可能设置晚于终端焦点回收
   - 修复：`TerminalPanelView.onAppear` 立即 `surface.setFocus(false)` + 三重焦点声明（sync + async + 50ms 延迟）

### 涉及文件
```
Sources/Composer/ComposerInputView.swift  — lastFocusedStateID、三重 makeFirstResponder
Sources/Panels/TerminalPanelView.swift    — .onAppear setFocus(false)
Sources/GhosttyTerminalView.swift         — 四个焦点路径守卫
```

### Git
```
3e0d2282 Fix auto-focus: disable terminal focus on appear + triple retry
36292484 Fix auto-focus on Composer reopen: track state identity not boolean flag
6167f8a8 Guard ALL focus reclamation paths against composer steal
```

---

## 五、Up/Down 历史记录

### 需求
输入框空白时按 Up/Down 查找之前发送过的 prompt。

### 方案
- `ComposerState.sendHistory: [String]` 静态数组，跨 Composer 会话持久（最多 50 条）
- `recordSentText()` 在 `sendComposerText` 时调用，去连续重复
- `historyUp()` / `historyDown()` 导航，保存当前未发送文本
- `doCommandBy(moveUp:/moveDown:)` 在空白或已进入历史模式时拦截
- `textDidChange` 中 `resetHistoryNavigation()` 退出历史模式

### 涉及文件
```
Sources/Composer/ComposerState.swift      — sendHistory、historyUp/Down、recordSentText
Sources/Composer/ComposerInputView.swift  — doCommandBy moveUp/moveDown 拦截
Sources/Panels/TerminalPanel.swift        — sendComposerText 调用 recordSentText
```

### Git
```
d37d121c Auto-focus on open + Up/Down history navigation in Composer
```

---

## 六、UI 调整

### Pill 文字截断
- `cellSize()` 宽度计算加 `ceil()` + 2pt 安全余量

### Sidebar 布局
- "Anson's"（大写 A、#08F 蓝色）移到问号按钮右边同一行（VStack → HStack）

### Dev build banner
- `THIS IS A DEV BUILD`（红色）→ `Anson's`（#08F 蓝色）

### 涉及文件
```
Sources/ContentView.swift — SidebarDevFooter 布局 + 文字颜色
```

### Git
```
064c8b95 Fix pill truncation, multi-image send, sidebar layout
8abaddd0 Inline pill thumbnails with hover preview + change dev banner to anson's
```

---

## 七、完整 Git 日志

```
6167f8a8 Guard ALL focus reclamation paths against composer steal
36292484 Fix auto-focus on Composer reopen: track state identity not boolean flag
3e0d2282 Fix auto-focus: disable terminal focus on appear + triple retry
d37d121c Auto-focus on open + Up/Down history navigation in Composer
966a6517 Remap keyboard shortcuts: Enter=send, Shift+Enter=newline, Cmd+Enter=send+submit
064c8b95 Fix pill truncation, multi-image send, sidebar layout
8abaddd0 Inline pill thumbnails with hover preview + change dev banner to anson's
96fc32a6 Fix Paste grayed out for images: declare readable pasteboard types
a08d54e4 Inline thumbnail attachments for pasted/dropped images
475cf8b1 Image markers: fix screenshot paste, [IMAGE #N] display, resolve on send
298285db Panel-based Composer with focus fix
```
