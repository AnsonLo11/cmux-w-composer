# 08 - Composer 代码块输入 + Bash 对齐 + CWD 修复

> 对应原文：`agentcontext/08-composer-code-block-and-fixes-20260417-183000.md`
> 时间戳：2026-04-15 ~ 2026-04-17 — 分支 `panel-composer`

## 需求

三条需求打包：（1）bash 模式 `❯` prompt 和文字大小不一致、基线不对齐，改为在 NSTextView 内部用同一字体绘制 + exclusionPaths 留位；（2）`@`/Tab 补全的 cwd 随 shell `cd` 漂移和 CC project root 不一致，改为优先读 `requestedWorkingDirectory`（surface 创建时固定）；（3）Composer 内实现代码块输入——三种围栏触发（``` / ～～～ / ···）+ `/code` 触发，全宽深色圆角背景，语法高亮，Shift+Enter 扩展，Up/Down/Backspace 边界导航，序列化为标准 markdown 围栏。

## 技术方案

**❯ 对齐**：删 SwiftUI `Text`，在 `ComposerNSTextView.draw(_:)` 用 NSFont + textContainerInset 绘制，`exclusionPaths` 留首行左侧空间。

**CWD**：`TerminalPanelView` cwdProvider 优先级交换——`requestedWorkingDirectory`（不变）优先于 `panel.directory`（OSC-7 实时）。

**代码块**：经历三次架构迭代——（1）`draw(_:)` override 读 NSLayoutManager line fragments → stale layout 时序问题；（2）NSTextBlock → `isRichText=false` 下矩形缩成 pill；（3）**最终方案 `CodeBlockLayoutManager: NSLayoutManager`**，手搭 TextKit 1 栈（绕过 macOS 12+ 默认 TextKit 2），override `drawBackground(forGlyphRange:at:)` 在 TextKit 渲染管线内部画深色矩形，零时序问题。数据模型 `.cmuxCodeBlock` attribute key + `ComposerState.codeBlocks` + `textWithCodeFencesApplied` 序列化。Up/Down/Backspace 用 `textStorage.insert(NSAttributedString)` 显式属性（避免 `isRichText=false` 下属性继承不可预测）。

## 实际执行

修改文件：`ComposerInputView.swift`（主体）、`ComposerState.swift`（数据模型/序列化）、`TerminalPanelView.swift`（CWD）。新增测试 `CodeBlockTests.swift`（22 tests 全绿）。主要踩坑：draw-time layout 时序（最大坑，迁到 LayoutManager 根治）、TextKit 2 回退（手搭 TK1 栈）、NSTextBlock 在非 rich text 下失效、`textView.replaceCharacters` 属性继承不可靠（改 textStorage 直接操作）。Build tag `code-block`。
