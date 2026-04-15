# Composer 焦点 Bug 修复 + cmuxTests/Composer 单元测试

> 时间戳：2026-04-15 15:55
> 分支：`panel-composer`
> 前序记录：`05-*`（panel-composer 完整变更）
> 本次工作：用户反馈 panel composer **永远** 抢不到焦点（typing 全跑去 CC，粘贴的图片以路径文本形式落入 CC 输入框）。本文档记录 root cause、修复、以及为这条焦点链路兜底的回归测试。

---

## 一、用户报的真实 bug

> "现在无论如何焦点都会留在 claude code 输入框而不是 composer 中；他有时候甚至会出现在这里 `/Users/ansonlo/.claude/image-cache/cmux-composer/image_1.png`，然后输入以后就会自动放入 cc 输入框。总之焦点自动跳转完全是失败的。"

症状：
1. ⌘⇧I 召唤 composer 后，焦点仍在终端
2. 用户 ⌘V 粘贴图片 → `TerminalImageTransferPlanner` 把图片存到 `~/.claude/image-cache/cmux-composer/` 然后 shell-escape 后塞进 PTY → CC 看到一行图片路径
3. 后续敲键继续进 CC，composer 永远拿不到 firstResponder

旁证一致：路径出现在 CC 而非 composer 内联 pill，说明粘贴事件压根没经过 ComposerNSTextView.paste，而是被 GhosttyNSView 拦下了。

---

## 二、Root cause

`Sources/Composer/ComposerInputView.swift` 里 `ComposerTextViewRepresentable.updateNSView` 的自动聚焦逻辑：

```swift
let currentStateID = ObjectIdentifier(composerState)
if context.coordinator.lastFocusedStateID != currentStateID,
   let window = nsView.window,           // ← 关键 guard
   textView.superview != nil {
    context.coordinator.lastFocusedStateID = currentStateID
    window.makeFirstResponder(textView)
    DispatchQueue.main.async { ... }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ... }
}
```

**SwiftUI 对 NSViewRepresentable 第一次调 `updateNSView` 时，NSScrollView 还在 mount 中，`nsView.window` 是 `nil`** → 整个 if 块被跳过 → `lastFocusedStateID` 也没 set。

正常 SwiftUI 会在状态变化时再调 `updateNSView`，那时 view 已经在 window 里。但 panel composer 召唤之后，`composerState` 的 `@Published` 属性 (`text`/`showCompletion`/...) 不会自动变化 → **永远不会有第二次 `updateNSView`** → 焦点永久卡在终端。

旁证：写 unit 测试时初版 5/7 失败完全同症状（fr 是 `<NSWindow>` 自己或 `TerminalLikeView`，从来不是 textView）。当时拿 `composerState.objectWillChange.send()` 强行触发第二次 updateNSView "绕过"了——等于把测试改成跟生产同样无能为力，所以测试全绿但 bug 没暴露。

---

## 三、修复（`Sources/Composer/ComposerInputView.swift`）

加一条 `viewDidMoveToWindow` 兜底：textView 真正进 window 那一刻再 claim 一次。这是 AppKit "我已经被挂到 window 了" 的官方钩子，正好补 SwiftUI updateNSView 时机不准的洞。

### 3.1 `ComposerNSTextView` 加 tripwire

```swift
private final class ComposerNSTextView: NSTextView {
    var placeholderText: String = ""
    var onBecomeFirstResponder: (() -> Void)?
    var onImagePasted: (() -> Void)?
    /// Set by makeNSView (and re-armed by updateNSView when a fresh
    /// ComposerState appears). Causes the next viewDidMoveToWindow callback
    /// to claim firstResponder, which is the only reliable signal that the
    /// SwiftUI tree has finished mounting this text view inside its window.
    var pendingAutoFocusOnWindowAttach: Bool = false
    ...

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard pendingAutoFocusOnWindowAttach, let window = self.window else { return }
        pendingAutoFocusOnWindowAttach = false
        window.makeFirstResponder(self)
    }
}
```

### 3.2 `makeNSView` 总是 arm tripwire

```swift
scrollView.documentView = textView
scrollView.onCmdEnter = { ... }

// Belt-and-braces with updateNSView — fires on every fresh mount even if
// SwiftUI's first updateNSView happens before nsView.window is set.
textView.pendingAutoFocusOnWindowAttach = true

return scrollView
```

### 3.3 `updateNSView` 也 arm（即便 window 是 nil）

```swift
let currentStateID = ObjectIdentifier(composerState)
if context.coordinator.lastFocusedStateID != currentStateID,
   textView.superview != nil {
    context.coordinator.lastFocusedStateID = currentStateID
    // Always arm — only signal that fires deterministically after mount.
    textView.pendingAutoFocusOnWindowAttach = true
    if let window = nsView.window {
        // Window already there: do the immediate + retry claims.
        window.makeFirstResponder(textView)
        DispatchQueue.main.async { ... }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ... }
    }
    // If window is nil, viewDidMoveToWindow handles it.
}
```

关键改动：把 `let window = nsView.window` 从 if-guard 里**移出**，改成 if-let 包住 immediate-claim 路径。原版 if-guard 失败会跳过 `lastFocusedStateID = currentStateID` 这一行——bug 的根因。

---

## 四、回归测试（`cmuxTests/Composer/`）

新增两个测试文件 + Composer 子组（PBXGroup）+ pbxproj 注册。

### 4.1 文件清单

```
新增
├─ cmuxTests/Composer/ComposerFocusTests.swift        # 4 个用例
└─ cmuxTests/Composer/ComposerDismissTests.swift      # 3 个用例

修改
└─ GhosttyTabs.xcodeproj/project.pbxproj
   ├─ PBXFileReference  +2 (ComposerFocusTests.swift, ComposerDismissTests.swift)
   ├─ PBXBuildFile       +2 (in cmuxTests Sources phase)
   └─ PBXGroup           +1 (Composer 子组挂在 cmuxTests group 下)
```

### 4.2 测试基础设施约定

两个 test class 都遵循同一套：

```swift
@MainActor
final class ComposerXxxTests: XCTestCase {
    private var window: NSWindow!
    private var composerState: ComposerState!
    private var hostingView: NSHostingView<ComposerInputView>?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared        // 确保 NSApp 起来
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: ...)
        window.makeKeyAndOrderFront(nil)
        composerState = ComposerState()
    }

    private func mountComposer() -> NSHostingView<ComposerInputView> {
        let view = ComposerInputView(
            composerState: composerState,
            onSend: { _ in }, onSendAndSubmit: { _ in },
            onDismiss: { }, onTextViewBecameFirstResponder: { }
        )
        let host = NSHostingView(rootView: view)
        host.frame = window.contentView?.bounds ?? ...
        host.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(host)
        // 顺序很关键，否则触发 NSHostingView 重入 layout 警告，layout pass 被跳：
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        // 不调 objectWillChange.send()——故意只走生产 auto-focus 链路。
        // 如果以后 viewDidMoveToWindow 兜底丢了，这些测试会立刻飘红。
        let deadline = Date(timeIntervalSinceNow: 0.3)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        hostingView = host
        return host
    }
}
```

### 4.3 测试用例

**ComposerFocusTests**（4 个）：
| 用例 | 验证 |
|------|------|
| `testTextViewBecomesFirstResponderOnMount` | mount 后 `window.firstResponder` 是 ComposerNSTextView（或其 descendant） |
| `testFocusReclamationGuardRecognizesActiveComposer` | `GhosttySurfaceScrollView.isResponderInsideComposerView(fr)` 返回 true |
| `testFocusReclamationGuardRejectsUnrelatedView` | 把无关 NSView 喂给 gate，必须返回 false（防误伤） |
| `testTerminalReclamationLeavesComposerFocusedWhenComposerIsActive` | 模拟生产 4 条 reclaim path 的 gate-check tick：composer mounted 时 gate 必须说 "don't steal"，且 fr 仍在 composer 上 |

**ComposerDismissTests**（3 个）：
| 用例 | 验证 |
|------|------|
| `testFirstResponderIsNoLongerInsideComposerAfterDismiss` | dismiss 后 fr 不再属于 composer 子树 |
| `testTerminalStandInRegainsFirstResponderAfterDismiss` | dismiss 后 `window.makeFirstResponder(terminalStandIn)` 必须成功 |
| `testFocusRoundTripTerminalToComposerAndBack` | 终端持有焦点 → mount composer（自动夺焦）→ dismiss → 终端可以再夺回 |

`TerminalLikeView`（dismiss 测试里 setUp 加入的 sibling，acceptsFirstResponder 极简 NSView）替代真实 Ghostty surface。Ghostty 初始化太重，单测里不构造。

### 4.4 跑测试

**用 xcodebuild（最直接）：**
```bash
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux-unit \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-composer-tests \
  -only-testing:cmuxTests/ComposerFocusTests \
  -only-testing:cmuxTests/ComposerDismissTests \
  test
```

跑全部 cmuxTests：去掉两个 `-only-testing:` 行即可。

**期望输出**：
```
Test Suite 'ComposerFocusTests' passed
Test Suite 'ComposerDismissTests' passed
Executed 7 tests, with 0 failures
** TEST SUCCEEDED **
```

---

## 五、XcodeBuildMCP 配置（避免下次踩坑）

`claude mcp add XcodeBuildMCP -s user -- npx -y xcodebuildmcp@latest mcp` 在这台机器上**直接装会失败**：

| 阻塞 | 原因 | 解决 |
|------|------|------|
| `EACCES` on `~/.npm/_cacache` | 历史 sudo 留下的 root-owned 缓存 | env 里塞 `NPM_CONFIG_CACHE=/tmp/npm-cache-cmux` 绕过 |
| `ECONNREFUSED 127.0.0.1:7897` | npm 配了本地 Clash/v2ray 代理但代理离线 | env 里清掉 `NPM_CONFIG_PROXY=` 和 `NPM_CONFIG_HTTPS_PROXY=` |
| 没有 `diagnostic` 工具 | 默认未启用对应 workflow flag | 用 `session_show_defaults` 当替代 health check |
| 没有 `test_macos_proj` / `build_macos_proj` | 默认只开 simulator workflow | 加 `XCODEBUILDMCP_GROUP_MACOS_WORKFLOW=true` |

**完整推荐配置：**
```bash
claude mcp remove XcodeBuildMCP -s user
claude mcp add XcodeBuildMCP -s user \
  -e NPM_CONFIG_CACHE=/tmp/npm-cache-cmux \
  -e NPM_CONFIG_PROXY= \
  -e NPM_CONFIG_HTTPS_PROXY= \
  -e XCODEBUILDMCP_GROUP_MACOS_WORKFLOW=true \
  -- npx -y xcodebuildmcp@latest mcp
```

加完 env 之后 **必须重启 Claude Code session** —— MCP 工具是在 session 启动时枚举的，不会运行时刷新。

---

## 六、单测踩坑记录（写测试时遇到的）

### 6.1 NSHostingView 重入 layout 警告

```
[Invalid Configuration] NSHostingView is being laid out reentrantly while
rendering its SwiftUI content. ... the current layout pass will be skipped.
```

触发条件：`addSubview(host)` 之后立刻调 `host.layoutSubtreeIfNeeded()`。

修复：必须按这个顺序——
```swift
contentView.addSubview(host)
window.displayIfNeeded()
contentView.layoutSubtreeIfNeeded()
// 不要再调 host.layoutSubtreeIfNeeded()
RunLoop.main.run(until: ...)
```

### 6.2 测试初版误用 `objectWillChange.send()` 掩盖了真 bug

写第一版 mountComposer 时为了让自动聚焦在测试里跑通，加了：
```swift
composerState.objectWillChange.send()  // ← BAD
```
让测试 7/7 全绿。

但生产里 composerState 不会自动变 → 永远不会有第二次 updateNSView → 焦点永久失败。**测试和生产用两套不同的触发路径，等于测试在做一道生产做不出的题。**

修复：**删掉** workaround，给生产代码加 viewDidMoveToWindow 兜底。两边都靠同一条路径走通，测试才有意义。

经验：mock / workaround / 强制触发只有当**生产代码也用同样手段**时才合理。否则就是把 bug 用胶带糊住。

---

## 七、Git 改动（panel-composer 分支）

```
M  Sources/Composer/ComposerInputView.swift
   - +pendingAutoFocusOnWindowAttach + viewDidMoveToWindow override
   - makeNSView arm tripwire
   - updateNSView 把 window guard 从 if-condition 移到 if-let 内部
A  cmuxTests/Composer/ComposerFocusTests.swift
A  cmuxTests/Composer/ComposerDismissTests.swift
M  GhosttyTabs.xcodeproj/project.pbxproj
   - +2 PBXFileReference / +2 PBXBuildFile / +1 PBXGroup (Composer)
A  agentcontext/06-composer-focus-fix-and-tests-20260415-155500.md (this file)
```

---

## 八、手测 checklist

1. `./scripts/reload.sh --tag panel-composer`
2. **退出旧的** `cmux DEV panel-composer.app`（内存里还是旧 binary）
3. cmd-click 打开新 build：`/Users/ansonlo/Library/Developer/Xcode/DerivedData/cmux-panel-composer/Build/Products/Debug/cmux DEV panel-composer.app`
4. 起 CC 会话
5. ⌘⇧I → composer 出现，焦点立刻到输入框（光标闪烁）
6. **不点 composer**，直接敲键 → 字符进 composer，不进 CC
7. 中文 IME 切到输入法，敲拼音 → 候选词正常出现在 composer 里
8. ⌘V 粘一张截图 → composer 内出现 inline pill thumbnail（**不是**路径文本，**不是** CC 里的路径）
9. Esc → composer 关闭，焦点回到终端，CC 输入正常
10. ⌘⇧I 再召唤 → 草稿还在，焦点重新到 composer
