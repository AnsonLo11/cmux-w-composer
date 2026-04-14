# cmux Composer Input 功能

> 在终端面板底部加一个原生 `NSTextView` 输入框，专门用来组织长 prompt（特别是给 Claude Code 这类 AI agent 用），解决终端原生输入对中文输入法、鼠标定位光标、多行编辑支持差的问题。

## 一、用户视角

### 1.1 调用与使用
| 操作 | 默认快捷键 | 行为 |
|------|----------|------|
| 显示/隐藏 composer | **⌘⇧I** | 在当前聚焦的终端面板底部召唤/收起一个 ~80–200pt 高的输入框 |
| 输入 | — | 完整 macOS 文本编辑：中文/日文/韩文 IME、鼠标点击定位、⌘A/⌘Z、⌥+方向键跳词、复制粘贴等 |
| 发送 | **⌘Enter** | 把全部文本注入终端 stdin（保留换行），清空 composer，关闭 |
| 关闭 | **Esc** | 隐藏 composer，**草稿保留**（下次 ⌘⇧I 打开还在） |

快捷键完全可配置：Settings → Keyboard Shortcuts → Toggle Composer，也可直接编辑 `~/.config/cmux/settings.json` 的 `shortcut.toggleComposer` 键。

### 1.2 视觉
- 永远位于终端面板底部，宽度跟随面板
- 顶部一根 1pt 细线作为视觉边界
- 等宽字体（系统 monospace）+ 半透明背景（`.background.opacity(0.95)`）
- 空白时显示占位文本 *"Compose your prompt… (⌘Enter to send, Esc to dismiss)"*
- 跟随系统亮/暗外观

### 1.3 不在本期范围内
语法高亮、Markdown 预览、文件拖入、与具体 AI agent 协议集成（仅做按键注入）。

---

## 二、架构与代码结构

### 2.1 文件清单（新增 / 修改）

```
新增
├─ Sources/Composer/ComposerState.swift          # @ObservableObject，承载 text 草稿
└─ Sources/Composer/ComposerInputView.swift      # SwiftUI overlay + 三个 AppKit 私有类

修改
├─ Sources/KeyboardShortcutSettings.swift        # 注册 .toggleComposer Action（默认 ⌘⇧I）
├─ Sources/Panels/TerminalPanel.swift            # composerState、savedComposerDraft、toggleComposer/hideComposer/sendComposerText
├─ Sources/Panels/TerminalPanelView.swift        # 把 composerState 透传给 GhosttyTerminalView
├─ Sources/GhosttyTerminalView.swift             # 在 GhosttySurfaceScrollView 挂载 overlay + 焦点保护
├─ Sources/TabManager.swift                      # toggleComposer() + 监听 cmuxComposerDidSend / DidDismiss
├─ Sources/AppDelegate.swift                     # cmux_performKeyEquivalent 处理 .toggleComposer
├─ Resources/Localizable.xcstrings               # 加 composer.placeholder + shortcut.toggleComposer.label（en+ja）
└─ GhosttyTabs.xcodeproj/project.pbxproj         # 注册新文件
```

### 2.2 数据流（聚焦 → 召唤 → 发送）

```
[User ⌘⇧I]
    │
AppDelegate.cmux_performKeyEquivalent
  matchConfiguredShortcut(.toggleComposer)
    └─→ TabManager.toggleComposer()
           └─→ selectedTerminalPanel.toggleComposer()
                  ├─ if composerState != nil  → hideComposer()
                  └─ else  → composerState = ComposerState(text: savedDraft)

[SwiftUI re-render]
    │
TerminalPanelView    (panel.composerState 是 @Published)
    └─→ GhosttyTerminalView.updateNSView
           └─→ GhosttySurfaceScrollView.setComposerOverlay(composerState:)
                  ├─ nil   → 移除 NSHostingView<ComposerInputView>
                  └─ 非 nil → 创建/复用 NSHostingView，addSubview，
                              立刻 surface.setFocus(false) + makeFirstResponder(textView)

[User 输入] → 走标准 NSTextView，IME / 鼠标 / 多行全部由 AppKit 处理

[User ⌘Enter]
    │
ComposerScrollView.performKeyEquivalent
  → Coordinator.parent.onSend()
    → GhosttySurfaceScrollView 里组装的 onSend
       → NotificationCenter.post(.cmuxComposerDidSend, object: terminalSurface)

[TabManager 监听]
  接收 .cmuxComposerDidSend
    → terminalPanel(tabId:panelId:).sendComposerText()
       ├─ surface.sendInput(text)         ← 唯一一处真实写入 PTY
       ├─ savedComposerDraft = ""         ← 发送后清空草稿
       └─ composerState = nil             ← 关闭 overlay

[User Esc]
    │
ComposerNSTextView.doCommandBy(cancelOperation:)
  → onDismiss()
    → NotificationCenter.post(.cmuxComposerDidDismiss, object: terminalSurface)
    → moveFocus()                          ← 把焦点交回终端

[TabManager 监听]
  接收 .cmuxComposerDidDismiss
    → terminalPanel.hideComposer()
       ├─ savedComposerDraft = composerState.text   ← 保留草稿
       └─ composerState = nil
```

### 2.3 状态持久化策略
- `ComposerState` 只持有当前会话的 `text`
- `TerminalPanel.savedComposerDraft: String` 在 hide 时拷一份，下次召唤时灌回
- 发送后清空（草稿生命周期 = 一次输入意图）
- 不持久化到磁盘（关闭 app 即丢失）— 简单且符合"临时草稿"的语义

### 2.4 关键设计决策
| 决策 | 原因 |
|------|------|
| Overlay 挂在 `GhosttySurfaceScrollView`（AppKit portal 层），不在 SwiftUI 容器层 | 严格遵循 CLAUDE.md 的 layering contract — terminal portal 在 split/workspace 重布局时会临时盖住 SwiftUI 层，overlay 必须跟它在一起 |
| 用 `NSTextView` 不用 SwiftUI `TextEditor` | IME 完整、底层可控、能做 placeholder 自绘、能精确拦截 ⌘Enter |
| ⌘Enter 在自定义 `NSScrollView.performKeyEquivalent` 里拦截，**不在** `doCommandBy` 拦截 | `doCommandBy` 收不到带 Cmd 修饰的组合键 |
| Send 和 Dismiss 用 `NotificationCenter`，不直接调 TabManager | overlay 的 callback 闭包对 `TerminalPanel` 弱引用困难，用通知能优雅解耦 |
| `sendComposerText()` 是唯一调 `surface.sendInput()` 的地方 | 第一版我在 overlay callback 和 panel 方法里都调了一次 → 双重发送 bug，code review 抓出来了 |
| `savedComposerDraft` 放在 `TerminalPanel`，不放在 `ComposerState` | composerState 生命周期 = 显示期间；草稿要跨显示期间存活 |

---

## 三、踩坑与修复（焦点这件事）

### 3.1 第一版 bug：字符在 composer 和终端之间来回跳

实测打字 "what?" 出现的结果：
- composer 里：`ddydww?`
- 终端里：`WHATW?`

明显是 first responder 在两边震荡。

### 3.2 根因
cmux 的终端有一套**焦点回收链路**，在很多场景（窗口切换、layout 变更、鼠标进出、定时检查）会主动把 first responder 设回 `surfaceView`：

- `GhosttySurfaceScrollView.ensureFocus(for:surfaceId:)` — 关键的 `window.makeFirstResponder(surfaceView)` 调用
- `GhosttySurfaceScrollView.applyFirstResponderIfNeeded()` — 同样
- `reassertTerminalSurfaceFocus(reason:)` — 反复调 `terminalSurface.setFocus(true)`，让 Ghostty 内部光标继续闪
- `TerminalPanel.focus()` → `hostedView.ensureFocus(...)`

cmux 的 search overlay (⌘F 查找框) 已经处理过同样的问题，模式是：
- `searchFocusTarget` 状态机
- `restoreSearchFocus(window:)` — 在 ensureFocus 命中时优先恢复 search 框焦点
- `isSearchOverlayOrDescendant(_:)` — 跨 surface 守卫，别的 surface 不能抢

Composer 第一版完全没接入这套机制，下一次 ensureFocus 触发就把焦点抢走了。

### 3.3 修复方案（mirror search 的整套模式）

**A. 三个新 helper（`GhosttyTerminalView.swift` 内 GhosttySurfaceScrollView）：**
```swift
private func isComposerOverlayOrDescendant(_ responder: NSResponder) -> Bool
private func mountedComposerTextView() -> NSTextView?
private func restoreComposerFocus(window: NSWindow)
```

**B. 在两条焦点关键路径加 guard**（`ensureFocus`、`applyFirstResponderIfNeeded`），紧跟 search 检查后面：
```swift
if composerOverlayHostingView != nil {
    restoreComposerFocus(window: window)
    return                  // ← 不再 makeFirstResponder(surfaceView)
}
```

**C. 跨 surface 守卫**（`isResponderInsideAnyComposerOverlay`），防止其他面板的 `applyFirstResponderIfNeeded` 抢这个面板的 composer 焦点。

**D. Mount 时立即让 surface 失焦 + 抢首响应者**：
```swift
addSubview(overlay)
surfaceView.terminalSurface?.setFocus(false)
DispatchQueue.main.async {
    self.surfaceView.terminalSurface?.setFocus(false)
    window.makeFirstResponder(textView)
}
```

**E. TextView 反向通知 surface 失焦**（`ComposerInputView.swift`）：
- `ComposerNSTextView` 重写 `becomeFirstResponder()`，触发回调
- `Coordinator.textDidBeginEditing` 也触发同一回调
- 回调路径：`onTextViewBecameFirstResponder` → `terminalSurface.setFocus(false)` — 关掉 Ghostty 内部光标闪烁循环 + reassert 链路

**F. 不在 `updateNSView` 里强制抢焦点**（首版犯过的错）— 否则用户点别处后焦点立刻被偷回。改用 `Coordinator.hasAppliedInitialFocus` 标志，仅首次显示时焦点一次。

### 3.4 修复后行为
- 召唤后焦点立刻在 composer
- 输入只去 composer
- 中文输入法可用（NSTextView 原生支持）
- 鼠标点击 composer 内任意位置可定位光标
- ⌘Enter / Esc 行为正确
- 终端这边不会闪烁光标（因为 setFocus(false) 已经告诉 Ghostty）

---

## 四、相关 API 与扩展点

### 4.1 添加更多输入快捷键
在 `ComposerNSTextView` / `ComposerScrollView` 里加，参考 ⌘Enter 的模式（在 `performKeyEquivalent` 里拦截带修饰键的组合）。

### 4.2 改变 overlay 高度
`ComposerInputView.swift` 顶部：
```swift
private static let minHeight: CGFloat = 80
private static let maxHeight: CGFloat = 200
```

### 4.3 草稿持久化到磁盘
`TerminalPanel.savedComposerDraft` 在 `init` 时从 `UserDefaults` 读，setter 时写入。注意一个 panel 一份，按 surfaceId 区分。

### 4.4 集成到非终端面板（如 Browser）
当前只挂在 `TerminalPanel`。如果要给 `BrowserPanel` 也加，需要：
- `BrowserPanel` 增加 `composerState`
- `BrowserPanelView` 透传
- Browser 那边的 first responder 模型不太一样（WKWebView），需要自己的焦点保护策略

### 4.5 把发送目标改为非 PTY 路径
当前 `TerminalPanel.sendComposerText()` 调 `surface.sendInput(text)`，这个会逐字符送入 ghostty input pipeline，控制字符（`\n`、`\t`、`\x1b`）会被翻译成对应 key event。如果某些 AI agent 想要 paste-like 一次送入，可改为构造 OSC 52 paste 或 bracketed paste 序列。

---

## 五、斜杠命令补全（V2）

### 5.1 命令注册表

`Sources/Composer/SlashCommandRegistry.swift` — 多源聚合，单例 `SlashCommandRegistry.shared`：

| 来源 | 路径 | 优先级 |
|------|------|--------|
| 内置命令 | `Resources/slash-commands.json` | 最低 |
| 插件 skill | `~/.claude/plugins/installed_plugins.json` → `{installPath}/skills/*/SKILL.md` | 中 |
| 用户自定义命令 | `~/.claude/commands/*.md` | 高 |
| 项目自定义命令 | `.claude/commands/*.md` | 最高 |

- Composer 显示时异步加载，60 秒内不重复加载
- 插件命令命名：`{plugin}:{skill}`，同名时缩写为 `{skill}`
- SKILL.md 解析 YAML frontmatter 的 `name` 和 `description`
- 自定义命令取文件名（去 `.md`）为名，第一个 `# heading` 为描述

### 5.2 补全弹窗

`Sources/Composer/SlashCompletionView.swift` — SwiftUI overlay 定位在 Composer 文本框上方：

- 触发条件：文本以 `/` 开头且光标在命令 token 内（第一个空格之前）
- 左侧：匹配的命令列表，最大 300pt 高、320pt 宽
- 右侧：选中项的描述 tooltip（深色背景 + 白色文字）
- ↑↓ 移动选择，Tab/Enter 确认插入，Esc 仅关闭弹窗

### 5.3 文本变色

识别到完整的已知命令时，`/command` 变蓝色（`NSColor.systemBlue`）。
通过 `NSTextStorage` 属性实现，在 `textDidChange` 中触发。

## 六、图片输入（V2）

### 6.1 粘贴图片

`ComposerNSTextView.paste(_:)` — 检测剪贴板：
- 有纯文本 → 默认粘贴
- 有图片数据 → `GhosttyPasteboardHelper.saveImageFileURLIfNeeded()` → 插入 shell-escaped 路径

### 6.2 拖拽图片

注册 `.fileURL`, `.png`, `.tiff` 拖拽类型。
`performDragOperation` 使用 `TerminalImageTransferPlanner.prepare()` 处理。

### 6.3 附件按钮 (+)

Composer 左下角的 `+` 按钮，打开 `NSOpenPanel` 选择图片文件，插入路径。

## 七、本地化键

| Key | en | ja |
|------|----|----|
| `shortcut.toggleComposer.label` | Toggle Composer | コンポーザーを切替 |
| `composer.placeholder` | Compose your prompt… (⌘Enter to send, Esc to dismiss) | プロンプトを入力… (⌘Enterで送信、Escで閉じる) |
| `composer.attachImage.help` | Attach image | 画像を添付 |
| `composer.attachImage.panelMessage` | Select images to attach | 添付する画像を選択 |

加新语言时直接在 `Resources/Localizable.xcstrings` 里加 localization 即可。

---

## 八、测试方法

> CLAUDE.md 明确禁止本地跑 E2E/UI 测试（必须走 CI 或 VM）。手测步骤：

### 基础功能（V1）
1. `./scripts/reload.sh --tag composer --launch`
2. 在终端里启动一个 Claude Code 会话
3. ⌘⇧I → composer 出现，焦点在输入框
4. 切到中文输入法，输入"你好世界" — 应正常显示，可正常用空格选词
5. 鼠标点输入框中间某处 — 光标应跳到点击位置
6. 输入多行（Enter 换行不发送）
7. ⌘Enter — 整段文本注入终端，composer 关闭并清空
8. ⌘⇧I 再次召唤 — 草稿应该是空的（因为发送过了）
9. 输入一些字 → Esc → 再 ⌘⇧I — 草稿应该还在
10. 多 split 的窗口，切到另一个面板再切回来 — composer 焦点应保持

### 斜杠补全（V2）
11. 输入 `/` — 补全弹窗应出现，列出所有已知命令
12. 继续输入 `com` — 列表过滤到 `compact`, `context` 等匹配项
13. ↑↓ 切换 — 选中项高亮，右侧显示描述
14. Tab 或 Enter — 命令插入到文本框，弹窗关闭
15. 输入 `/compact` — 文本应变蓝色
16. 输入 `/compact ` (加空格) — 弹窗应已关闭
17. Esc — 弹窗可见时仅关弹窗，不关 Composer

### 图片输入（V2）
18. 截屏后 ⌘V — 应插入临时文件路径（如 `/tmp/cmux-clipboard-...png`）
19. 从 Finder 拖入图片 — 应插入文件路径
20. 点击 + 按钮 — 应打开文件选择器，选择后插入路径

如果出现"字符跑去终端"，第一时间打开 debug 日志看焦点事件：
```bash
tail -f "$(cat /tmp/cmux-last-debug-log-path 2>/dev/null || echo /tmp/cmux-debug.log)" | grep -E 'focus|composer'
```
