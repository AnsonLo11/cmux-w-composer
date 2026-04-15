# 04 - Composer V2 UI 打磨：发送按钮 + 比例 + 可拖拽高度

> 对应原文：`agentcontext/04-composer-v2-ui-polish-20260414-160915.md`
> 时间戳：2026-04-14 16:09

## 需求

V2 功能跑通后做一轮 UI 收口，参考 ChatGPT/Claude 的工具栏视觉规范：

1. **圆形发送按钮**：删除工具栏右侧 "/ for commands" 提示文字，替换为类似 ChatGPT 上箭头的圆形发送按钮。空内容时浅灰色，有内容后变深灰色。点击触发发送（等同 ⌘Enter）。
2. **加号按钮放大**：`+` 按钮和发送按钮的视觉比例对齐，参考主流 AI 工具栏图标大小。
3. **可拖拽调整 Composer 高度**：允许用户拖动 Composer 顶部边缘改变大小，高度范围限制在合理区间，拖拽时光标变化提供视觉反馈。

## 技术方案

**发送按钮**：直接用 SF Symbol `arrow.up.circle.fill`（28pt），无需自定义素材；颜色 `Color.primary.opacity(0.15)`（空）→ `0.5`（有内容）；`.disabled(composerState.text.isEmpty)` 防止空发送；tooltip "Send (⌘Enter)" 加入本地化。

**加号按钮**：`font(.system(size: 14))` 调到 `18`，加 `.frame(width: 28, height: 28)` 固定 hit area，与发送按钮 28pt 圆形等高对齐。

**可拖拽高度**：固定的 `minHeight`/`maxHeight` 改为 `@State private var composerHeight: CGFloat`（默认 120）+ `@GestureState private var dragOffset: CGFloat` 追踪拖拽偏移；计算属性 `effectiveHeight = composerHeight - dragOffset`，clamp 在 `[60, 400]`；顶部新增 `composerDragHandle` 视图——36pt 宽 3pt 高的圆角小条，`Color.primary.opacity(0.15)`，`.onHover` 切换 `NSCursor.resizeUpDown`。拖拽方向：上拖 = 增高（translation.height 为负，减去后变大）。`.frame(minHeight:maxHeight:)` 整段替换为 `.frame(height: effectiveHeight)`，工具栏 `.frame(height: 28)` 改为 `.padding(.vertical, 6)`。

## 实际执行

修改 `Sources/Composer/ComposerInputView.swift`（删 "/ for commands" 分支、新增发送按钮、加号按钮放大、新增 drag handle、固定高度替换为可调高度）；Localizable 删 `composer.slashHint` 新增 `composer.send.help`（"Send (⌘Enter)" / "送信 (⌘Enter)"）。

顺手修复了两处遗留问题：（1）`Resources/slash-commands.json` 里 6 条命令名带多余 `/` 前缀（`/teleport`→`teleport` 等），逐条 Edit；（2）`SlashCommandRegistry.loadBuiltinCommands()` 加 safety strip，加载时自动去除 name 的 `/` 前缀作为兜底。

编译验证一次过 BUILD SUCCEEDED，`./scripts/reload.sh --tag composer-v2` 出 `cmux DEV composer-v2.app`。常量变化总览：文本区高度 `(80, 200)` 固定 → `120` 默认（可拖拽 60-400）；+ 按钮 14→18 + 28x28；新增 28pt 圆形发送按钮；工具栏改用 padding 而非固定 height。
