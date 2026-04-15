# 06 - Composer 焦点 Bug 兜底修复 + cmuxTests/Composer 单测

> 对应原文：`agentcontext/06-composer-focus-fix-and-tests-20260415-155500.md`
> 时间戳：2026-04-15 15:55 — 分支 `panel-composer`

## 需求

用户反馈 panel-composer 上线后**永远抢不到焦点**：⌘⇧I 召唤 Composer 后焦点仍在终端，⌘V 粘贴图片 → `TerminalImageTransferPlanner` 把图存到 `~/.claude/image-cache/cmux-composer/` 后 shell-escape 塞进 PTY → CC 看到一行图片路径，后续敲键继续进 CC。旁证一致：路径出现在 CC 而非 composer 内联 pill，说明粘贴事件压根没经过 `ComposerNSTextView.paste`，而是被 GhosttyNSView 拦下了。需要修复并加回归测试守住这条焦点链路。

## 技术方案

**Root cause**：`ComposerTextViewRepresentable.updateNSView` 自动聚焦逻辑里 `if let window = nsView.window` 是关键 guard。SwiftUI 第一次调 `updateNSView` 时 NSScrollView 还在 mount 中，`nsView.window` 是 `nil` → 整个 if 块被跳过 → `lastFocusedStateID` 也没 set。正常 SwiftUI 会在状态变化时再调一次，但 panel composer 召唤之后 `composerState` 的 `@Published` 属性不会自动变化 → **永远不会有第二次 updateNSView** → 焦点永久卡在终端。

**修复**：加 AppKit 官方钩子 `viewDidMoveToWindow` 兜底——textView 真正进 window 那一刻再 claim 一次。`ComposerNSTextView` 加 `pendingAutoFocusOnWindowAttach: Bool` tripwire，`makeNSView` 总是 arm，`updateNSView` 里把 `let window = nsView.window` 从 if-guard 里移出改成 if-let 包住 immediate-claim 路径——这样即便 window 是 nil，`lastFocusedStateID = currentStateID` 这一行也照常执行，并 arm tripwire 等 `viewDidMoveToWindow` 接力。

## 实际执行

修改 `Sources/Composer/ComposerInputView.swift`（加 `viewDidMoveToWindow` override + `makeNSView` arm tripwire + `updateNSView` 把 window guard 从 if-condition 移到 if-let 内部）。新增 `cmuxTests/Composer/` 子组：`ComposerFocusTests.swift`（4 用例：mount 后 fr 是 textView、`isResponderInsideComposerView` gate 正确、gate 拒绝无关 view 不误伤、四条 reclaim path 的 gate-check tick 在 composer mounted 时返回不偷）+ `ComposerDismissTests.swift`（3 用例：dismiss 后 fr 不在 composer 子树、`TerminalLikeView` 能拿回 fr、终端→composer→终端 round trip）。pbxproj 加 `+2 PBXFileReference / +2 PBXBuildFile / +1 PBXGroup`。

**关键踩坑**：写测试初版用 `composerState.objectWillChange.send()` 强制触发让测试 7/7 全绿——但等于把测试改成跟生产同样无能为力，bug 没暴露。教训：mock/workaround/强制触发只有当**生产代码也用同样手段**时才合理；测试和生产用两套不同触发路径就是把 bug 用胶带糊住。删掉 workaround 后给生产代码加 viewDidMoveToWindow 兜底，两边走同一条路径测试才有意义。`mountComposer()` 还要按 `addSubview → window.displayIfNeeded() → contentView.layoutSubtreeIfNeeded()` 顺序，不能再调 `host.layoutSubtreeIfNeeded()`，否则触发 NSHostingView 重入 layout 警告 layout pass 被跳。

文档同时记录了 XcodeBuildMCP 在这台机器上的 npm cache EACCES、ECONNREFUSED proxy、缺 macOS workflow group 等阻塞和 env 兜底配置（`NPM_CONFIG_CACHE`、清空 `NPM_CONFIG_PROXY/HTTPS_PROXY`、`XCODEBUILDMCP_GROUP_MACOS_WORKFLOW=true`），加完必须重启 Claude Code session。
