# 07 - Composer `@` 文件补全 + Bash 模式（#0D1117 沉浸态）

> 分支：`panel-composer`
> 时间戳：2026-04-15 17:23
> 前序：`06-composer-focus-fix-and-tests-20260415-155500.md`

## 一、需求（用户原话 + 澄清后的解读）

用户提了 4 条需求并配了两张截图：

1. **弹窗对齐**：参考 `image_1.png`，`/` 补全弹窗当前居中浮在半空中，应当**左边缘与 composer 卡片左边缘齐平**。
2. **鼠标悬停飞滚 bug**：鼠标停在弹窗**正中间时不动**，但靠近**顶部或底部时，列表会类似拉滑条一样快速滚动**。要求减速或直接禁用。
3. **`@` 文件补全**：参考 `image_2.png`，「任何地方有空格+@的地方触发（不要求输入框为空）」，弹窗列出当前目录下的文件。视觉必须**复用 `/` 弹窗样式**。
4. **`!` Bash 模式**：空输入框首字输入 `!` 或 `！`（兼容中文）进入 bash 模式。要求：
   - 深色主题（#0D1117）、轻微渐变、噪点纹理、等宽字体
   - 最左侧弱提示 `$` 或 `❯`（低饱和强调色）
   - 块状或高对比竖线光标 + 呼吸闪烁动画
   - subtle glow 边框（蓝绿或琥珀色）
   - ↑↓ 浏览**独立的** bash 历史（不和上方聊天历史混）
   - Tab 提示补全（请评估可行性）
   - 退出时平滑过渡

开工前对 3 个模糊点发起澄清问题，用户回复如下：

| # | 澄清后定论 |
|---|-----------|
| Q1 | 需求 2 的「光标」指**鼠标**（表述笔误），问题出在**弹窗**内部而非 NSTextView 内部。 |
| Q2 | `@` 的「当前目录」= **终端进程当前 cwd**（随 `cd` 动态变化）。 |
| Q3 | Bash 模式按 Enter/Cmd+Enter 的发送语义 = **发送英文 `!command` 给 CC**（让 CC 自带的 `!` 命令处理）；即使触发时用户敲的是中文 `！`，前缀**必须**是英文 ASCII `!`。 |

用户最终选择执行 **P1 + P2 + P3**，暂缓真 bash 补全、独立 shell 执行、终端 cursor 滚动。

---

## 二、技术方案（按任务顺序）

### 任务 0：诊断 hover-feedback loop 的根因

翻 `SlashCompletionView.swift:37-52`：

```swift
.onHover { hovering in
    if hovering { selectedIndex = index }          // 鼠标悬停→改 selectedIndex
}
.onChange(of: selectedIndex) { newIndex in
    withAnimation(.easeOut(duration: 0.1)) {
        proxy.scrollTo(newIndex, anchor: .center)  // 把它滚到正中央
    }
}
```

这就是完美的反馈环：鼠标悬停顶部 item → `selectedIndex=0` → 滚到中央 → 列表下移 → 鼠标下方冒出新 item → 又触发悬停 → 又滚 …… 正中央的 item 已经在中央，所以静止。**与用户描述一字不差。**

修复方案 A（采纳）：**彻底移除 `.onHover` 的 selection 绑定**（mouse 只负责点击，不改选中）；另外把 `scrollTo` 的 anchor 从 `.center` 改成 `nil`，仅在目标不可见时才滚（键盘 ↑↓ 走这条路）。VSCode/Cursor 全是这个交互。

### 任务 1：抽 `CompletionItem` 协议、泛化 `CompletionPopupView`

需求 3、任务 8 都需要同一个弹窗容器，所以**前置重构**一次到位：

```swift
protocol CompletionItem: Hashable {
    var name: String { get }
    var detail: String { get }
    var tagStyle: CompletionTagStyle { get }
}

struct CompletionTagStyle: Equatable {
    let label: String; let fg: Color; let bg: Color
}

struct CompletionPopupView<Item: CompletionItem>: View { ... }
```

`SlashCommand` 通过 `extension SlashCommand: CompletionItem` 就近实现（留在 `SlashCommandRegistry.swift`），把之前 `CommandRow` 里 switch-based 的 category 颜色变成 `SlashCommand.tagStyle` 计算属性。

文件改名：`SlashCompletionView.swift` → `CompletionPopupView.swift`（pbxproj `path` 字段替换，UUID 保留）。

### 任务 2：弹窗左对齐

外层 `VStack(spacing: 0)` 默认 `.center`；popup 比 card 窄 → 居中后偏移。改 `VStack(alignment: .leading, spacing: 0)` 一行解决。

### 任务 3：`@` 文件补全

拆成 3 块纯逻辑 + 1 条集成路径：

**`FileTokenDetector.detectAtToken(in:cursorOffset:) -> Match?`**
- UTF-16 based，和 `NSTextView.selectedRange` 对齐
- 从 cursor 往回走：遇到 whitespace 先→ 返回 nil（token 已闭合）；遇到 `@` 且前一位是 whitespace/newline/start-of-string → 命中；遇到 `@` 但前一位是字母（`email@domain`）→ 返回 nil
- 返回 `(range: NSRange, filter: String)`

**`FileCompletionProvider.list(cwd:filter:) -> [FileEntry]`**
- `FileManager.contentsOfDirectory`、`.git`/`node_modules`/`.DS_Store` 硬跳
- 大小写不敏感 `contains` 匹配
- 目录排前，locale-aware compare
- 200 条封顶

**`FileEntry: CompletionItem`**
- tag：目录 `Dir`（琥珀 #F59E0B）、文件 `File`（石板灰 #64748B）

**cwd 链路**：发现 `TerminalPanel` 已有 `@Published var directory`，但 `updateDirectory` 从未被调用，真实源是 `workspace.panelDirectories[panelId]`（OSC-7 驱动）。一行修复：`Workspace.updatePanelDirectory` 里追加 `terminalPanel(for: panelId)?.updateDirectory(trimmed)`。然后 `TerminalPanelView` 给 `ComposerInputView` 传入：
```swift
cwdProvider: { [weak panel] in
    let d = panel?.directory.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return d.isEmpty ? panel?.requestedWorkingDirectory : d
}
```

**ComposerState** 新增 4 个 `@Published`：`showFileCompletion`、`fileCompletionFilter`、`fileCompletionItems`、`fileCompletionSelectedIndex`，加一个普通 `fileCompletionTokenRange: NSRange`（用于替换时的定位）。

**Coordinator.textDidChange** 加一条 `updateFileCompletion(textView:)`：slash popup 可见则屏蔽；无 cwd 返回；否则列当前目录并打开弹窗。Coordinator.doCommandBy 加一段 file-popup 的键盘分支（↑↓/Tab/Enter/Esc），与 slash 分支并列。

**插入行为**：选中时 `onInsertFile(_ entry:)` 把 `@filter` token 范围替换为 `GhosttyPasteboardHelper.escapeForShell(entry.relativePath) + " "`，popup 关闭。

### 任务 4-5：Bash 模式状态机 + 发送前缀

**`ComposerState` 扩展**：
```swift
@Published var bashMode: Bool = false

static func shouldEnterBashMode(text: String) -> Bool {
    text == "!" || text == "\u{FF01}"
}

// 独立历史
private static var bashHistory: [String] = []
static func recordBashText(_ text: String) { ... }

// historyUp/Down 按 bashMode 分流到对应 history
func historyUp() -> String? {
    let history = bashMode ? Self.bashHistory : Self.sendHistory
    ...
}

// 出口统一走这个
func payloadForSending() -> String {
    bashMode ? "!" + resolvedTextForSending() : resolvedTextForSending()
}
```

**发送路径**：`TerminalPanel.sendComposerText` 只改 3 处 — 用 `payloadForSending()` 替代 `resolvedTextForSending()`、根据 `bashMode` 走 `recordBashText` 或 `recordSentText`。

**Coordinator.textDidChange** 在其它逻辑前加一段状态机：
- `!bashMode && shouldEnterBashMode(newText) && !hasMarkedText()` → `bashMode = true`，程序化清空 textView，`showCompletion = false`、`showFileCompletion = false`，提前 return
- `bashMode && newText.isEmpty` → `bashMode = false`，继续走正常逻辑

IME 守卫：用 `hasMarkedText()` 挡住组合中状态，避免敲中文时误触发。

### 任务 6：Bash 模式视觉主题

SwiftUI 侧在 composer card 的 background/overlay/shadow 三处做 `composerState.bashMode` 分叉，并把**整个 card** 包在 `.animation(.easeInOut(duration: 0.22), value: composerState.bashMode)` 里一键联动：

```swift
.background(composerBackground)  // 分叉：亮色 .background.opacity(0.97) / 暗色 gradient+noise
.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
    bashMode ? Self.bashAccent.opacity(0.55) : Color.primary.opacity(0.1),
    lineWidth: bashMode ? 1.5 : 1
))
.shadow(
    color: bashMode ? Self.bashAccent.opacity(0.35) : .black.opacity(0.06),
    radius: bashMode ? 10 : 3, y: 1
)
```

`composerBackground` 暗色版是 `LinearGradient(#0D1117 → #161B22, top→bottom)` 叠 `Canvas` 随机散点做噪点（每 900 px² 一个点，alpha 0.015–0.05，白色）。

**`❯` prompt**：外层改 `HStack(alignment: .top, spacing: 0)`，`bashMode` 为真时前置一个 `Text("\u{276F}")`，14pt SF Mono，bashAccent 色，`.top padding 10` 和 textView 首行对齐。进出带 `.opacity.combined(with: .scale(scale: 0.8))` transition。

**NSTextView 主题**：SwiftUI 动画不能传递到 AppKit，所以 `updateNSView` 检测 `textView.isBashMode != composerState.bashMode` 调 `applyBashModeAppearance(_:)`。该方法走 `NSAnimationContext.runAnimationGroup(duration: 0.2, allowsImplicitAnimation: true)`：

- 暗：`appearance = .darkAqua`、`drawsBackground = true`、`backgroundColor = #0D1117`、`textColor = white 0.92`、`insertionPointColor = bashAccent`
- 亮：全部复位，`insertionPointColor = .textInsertionPointColor`

Send 按钮前景色也分叉：暗色时用 bashAccent 色带透明度，保持视觉语言一致。

**Accent 颜色**：`#2EE59D`（薄荷/青），对深色背景对比度够，又不和 SwiftUI 的系统蓝冲突。

### 任务 7：块状光标 + 呼吸动画

核心 override：

```swift
override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
    guard isBashMode, !hasMarkedText() else {
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag); return
    }
    let charWidth = font?.maximumAdvancement.width ?? 8
    let block = NSRect(x: rect.minX, y: rect.minY + 1,
                       width: max(charWidth, 2), height: max(rect.height - 2, 2))
    let breath = 0.35 + 0.65 * (sin(bashBreathPhase) * 0.5 + 0.5)   // 0.35..1.0
    color.withAlphaComponent(CGFloat(breath)).setFill()
    NSBezierPath(roundedRect: block, xRadius: 1, yRadius: 1).fill()
}
```

系统的 `turnedOn` 闪烁信号**直接忽略**，自己用 `Timer(interval: 1/30, repeats: true)` 驱动 `bashBreathPhase += 0.13`（~1.6s 一个呼吸周期），每 tick `needsDisplay = true`。timer 注册在 `RunLoop.main.add(timer, forMode: .common)`，确保滚动/菜单交互期间不停。`applyBashModeAppearance` 开启时 `startBashCursorTimer`、关闭时 `stopBashCursorTimer`，`deinit` 再 invalidate 一次兜底。

IME 守卫：`hasMarkedText()` 为真时走 super，避免和组合光标冲突。

中文混排时 `maximumAdvancement.width` 不准 → 用 `font.pointSize * 0.55` 兜底（不走这条路的话块宽是 0，什么都看不到）。

### 任务 8：Bash 模式 Tab 补全（文件路径版）

复用 `FileCompletionProvider` + `CompletionPopupView<FileEntry>`，只新增一个分词器：

```swift
static func detectWordBeforeCursor(in text: String, cursorOffset: Int) -> WordMatch? {
    // 从 cursor 往回走，遇 whitespace 停，返回 [start+1, cursor) 的子串
    // 没有 whitespace 就返回 [0, cursor)
    // cursor==0 返回空字符串 + 空 range
}
```

`Coordinator.doCommandBy` 对 Tab 的处理插在 file-popup 分支**之前**：

```swift
if bashMode && !showFileCompletion && !showCompletion
   && commandSelector == #selector(NSResponder.insertTab(_:)) {
    triggerBashTabCompletion(textView: textView); return true
}
```

`triggerBashTabCompletion` 把 word 当 filter 跑 `FileCompletionProvider.list`，结果非空就 `showFileCompletion = true`。选中后 `onInsertFile` 的 range 替换逻辑和 `@` 完全共用。

---

## 三、实际执行：10 次提交 + 踩坑记录

### 提交时间线（按 branch head 倒序）

| SHA | 标题 | 性质 |
|-----|------|------|
| `92f1fa83` | Add Tab-triggered file completion in bash mode | 特性（5 测试） |
| `d34455c8` | Add block cursor with breathing animation for bash mode | 特性（纯视觉） |
| `b2e3876d` | Style bash mode: dark gradient + ❯ prompt + cyan glow + smooth transition | 特性（纯视觉） |
| `780e08b4` | Add bash-mode state machine, independent history, and '!' send prefix | 特性（10 测试） |
| `ca19129d` | Add @-triggered file completion for the composer (cwd-aware) | 特性（13 测试） |
| `3c1434d9` | Document no-onHover invariant for completion popup rows | 文档 |
| `1c3fd018` | Left-align completion popup to composer card | 特性（1 行 UI） |
| `392db8de` | Extract CompletionItem protocol and generic CompletionPopupView | 重构 |
| `5cd1df47` | Register composer focus regression tests and viewDidMoveToWindow fix | 会话前置 |
| `156f2206` | Add agentcontext preview summaries and focus-fix session doc | 会话前置 |

### 踩坑记录

1. **`subscript(safe:)` 重定义冲突**：`CompletionPopupView.swift` 新的 Array 扩展删了 `private`，和 `ComposerInputView.swift` 文件尾私有扩展撞名。`invalid redeclaration of 'subscript(safe:)'`。把 ComposerInputView.swift 尾部那块删掉，保留一条指向 CompletionPopupView.swift 的注释。

2. **pbxproj UUID 撞车**：首次给 `FileCompletion.swift` 分配 `A500C005`/`A500C014`，编译后 `FileCompletion.o` 压根没生成，只有 `CompletionPopupView.o`/`ComposerInputView.o`。`grep` 发现 `A500C005 /* slash-commands.json in Resources */` 和 `A500C014 /* slash-commands.json */` 已占用 — `sed -i` 式全局替换前没检查碰撞。换 `A500C006`/`A500C015`，build 立刻通。**教训**：在 pbxproj 里加 UUID 前先 `grep` 确认空槽。

3. **Task #3 的 hover 修复「被 Task #1 顺手吃掉」**：重构 CompletionPopupView 时同步去掉了 `.onHover` 绑定和 `anchor: .center`，结果 Task #3 只剩下加一条 invariant 注释的文档性提交。不算大问题，在两次 commit message 里互相引用做了交代。教训：**紧邻代码改动的 bug 修复，优先分开两次提交**（先重构、再修 bug），这样 `git bisect` 更清晰。

4. **`build_run_sim` 失败时 codesign 卡在 `cmuxTests.xctest not signed`**：build phase 的 codesign 步骤对 Extended Attribute 敏感，干扰 Swift 编译结果的判断。解决办法是**只看 SwiftCompile/error 行**，忽略末尾的 codesign + bundling 错误（本地不签名跑 unit test 不受影响；push CI 时会另签一套）。

5. **TerminalPanel.directory 一直是空字符串**：想从 panel 拿 cwd 时发现 `updateDirectory(_:)` 存在但没人调。真实 cwd 在 `workspace.panelDirectories[panelId]`（OSC-7 驱动）。一行修 `Workspace.updatePanelDirectory`：追加 `terminalPanel(for: panelId)?.updateDirectory(trimmed)`。这样 `@ObservedObject var panel` 的观察者（TerminalPanelView）就能在 cwd 变化时重新计算 `cwdProvider` 的捕获值。

6. **NSTextView 主题切换和 SwiftUI 动画不同步**：SwiftUI `.animation(value: bashMode)` 只能动它自己的 modifier 链，到不了 NSTextView 的 `backgroundColor` / `textColor`。解决：NSTextView 那边用 `NSAnimationContext.runAnimationGroup(duration: 0.2)` + `allowsImplicitAnimation = true` 自己做 200ms 淡入淡出，和 SwiftUI 的 220ms 错开 20ms，感知不到割裂。

7. **块光标 timer 和 IME**：最初 override `drawInsertionPoint` 时忘了 `hasMarkedText()` 守卫，敲中文时块光标会和 IME 组合候选高亮叠在一起。补 guard 后 IME 态走 super，正常。中文 IME 选完落字回到 bashMode，块光标恢复正常绘制。

### 测试覆盖

共 **28 个**新增单测，全绿。

| 套件 | 用例数 | 覆盖 |
|-----|-------|-----|
| `FileCompletionTests` | 18 | `@` token 9 边界 + Tab 分词 5 边界 + 列表 3 + tag 样式 1 |
| `BashModeTests` | 10 | 触发 5（英文/中文/多字符/空/其他字符）+ payload 3（bashMode 加前缀/始终英文/非 bashMode 无前缀）+ 历史隔离 3（独立读/chat 不漏 bash/bash 不漏 chat） |

无法写测试的部分（SwiftUI/NSTextView 纯视觉）在 commit message 里显式声明 rationale，按 `CLAUDE.md` 测试质量政策跳过。

### 构建产物

最终 build tag：`composer-bash`，app 路径：
```
/Users/ansonlo/Library/Developer/Xcode/DerivedData/cmux-composer-bash/Build/Products/Debug/cmux DEV composer-bash.app
```

---

## 四、手动验证清单（给人类走一遍）

1. **弹窗左对齐**：`/` → popup 左边缘贴合 composer 卡片左边缘
2. **悬停不飞滚**：鼠标在 popup 顶部/底部移动，列表静止；鼠标点击某行才触发插入
3. **`@` 补全**：`读取 @Sou` → 弹窗列出 cwd 里匹配 `Sou` 的条目；`cd` 到子目录后再打开 composer，列表应跟随
4. **`@` 不误触发**：`email@x` 不弹；`@foo bar` 光标在 `bar` 后不弹
5. **bash 触发**：空 composer 敲 `!` → 深色 + ❯ + 青色边框 + 块光标呼吸
6. **bash 退出**：全删 → 平滑回亮色
7. **`!` 前缀发送**：bashMode 输入 `ls -la` Cmd+Enter → CC 收到 `!ls -la\n`
8. **独立历史**：bashMode 按 ↑ 只看 bash 历史；退出 bashMode 后按 ↑ 只看 chat 历史
9. **Tab 补全**：bashMode `cat REA` Tab → 弹出 README.md 等候选；Enter 替换为 shell-escaped 路径
10. **中文 `！`**：切到中文 IME 敲 `！` → 进入 bashMode；发送时前缀仍是英文 `!`
11. **IME 兼容**：bashMode 下敲中文，组合候选和块光标不打架
