# 08 - Composer 代码块输入 + Bash 模式对齐修复 + CWD 修复

> 时间戳：2026-04-15 ~ 2026-04-17 — 分支 `panel-composer`

## 需求

三条主线需求 + 多轮迭代修复：

**需求 1：Bash 模式 `❯` 对齐**：SwiftUI `Text("❯")` 14pt 和 NSTextView 13pt 字号不一致，垂直对齐靠魔法数字。要求大小一致、基线对齐。

**需求 2：`@` / Tab 补全 CWD 与 Claude Code 一致**：当前 cwdProvider 优先读 `panel.directory`（shell 实时 CWD，随 `cd` 漂移），和 CC 的 project root 不一致。要求稳定指向 CC 启动时的目录。

**需求 3：Composer 代码块输入**：用户在行首输入 ``` / ～～～ / ··· 后进入代码块模式——深色全宽背景、语法高亮、Shift+Enter 扩展块、Enter 发送、Up/Down/Backspace 边界导航、`/code` 触发、序列化为标准 markdown 围栏。

## 技术方案

### 需求 1：❯ 对齐（方案 B → 方案 C 演进）

删掉 SwiftUI `Text("❯")`，改在 `ComposerNSTextView.draw(_:)` 用同一个 NSFont + textContainerInset 绘制。用 `textContainer.exclusionPaths` 在第一行左侧留出 prompt 宽度（只影响第一行，续行不受影响）。placeholder 文字在 bash 模式下右移避让。

### 需求 2：CWD（方案 C）

`TerminalPanelView.swift` cwdProvider 优先级交换：先读 `panel.requestedWorkingDirectory`（surface 创建时确定的路径，不随 shell `cd` 漂移），fallback 才用 `panel.directory`（OSC-7 实时 CWD）。`requestedWorkingDirectory` 是 `private let`，创建后不变——恰好是 CC 项目根的稳定代理。

### 需求 3：代码块（多轮重构）

#### 数据模型

`ComposerState` 新增：
- `CodeBlockSpan { range: NSRange, language: String }` — 代码块范围和语言标识
- `@Published var codeBlocks: [CodeBlockSpan]` — 由 Coordinator 从 textStorage 属性 runs 同步
- `parseFenceLine(_:)` — 识别 ``` / ～～～(U+FF5E) / ···(U+00B7) + 可选语言标识
- `textWithCodeFencesApplied(to:)` — 序列化时将 codeBlocks 范围包裹标准 markdown ``` 围栏
- `codeBlockFenceCharacters` — 三种触发字符常量

自定义属性 key `.cmuxCodeBlock`（NSAttributedString.Key）标记代码块字符，值为语言字符串。

#### 触发方式

1. **围栏触发**：行首 ``` / ～～～ / ···（+ 可选 lang）+ **Shift+Enter** → `attemptCodeBlockFenceTransition`
2. **`/code` 触发**：`/code` + 空格（textDidChange 检测）或 `/code` + Enter（doCommandBy 拦截）→ `attemptSlashCodeTrigger`，不限行首
3. 触发时插入 anchor `\n`（带 .cmuxCodeBlock 属性）+ 尾部 prose escape `\n`，cursor 在 anchor 之前，typingAttr = code

#### 代码块背景渲染（三次重构）

**第一版：`draw(_:)` override**（已废弃）。在 `ComposerNSTextView.draw(_:)` 里用 NSLayoutManager `enumerateLineFragments` 计算行片段矩形 → union → 画全宽圆角深色矩形。问题：text 变更后 layout 尚未 settle 时 draw 读到 stale 位置 → 残影、错位。尝试了 `ensureLayout`、`DispatchQueue.main.async needsDisplay`、NSBezierPath clip to bounds 等缓解措施，均无法根治时序问题。

**第二版：NSTextBlock**（已废弃）。自定义 `CodeBlockTextBlock: NSTextBlock` 子类 + 段落 `.paragraphStyle.textBlocks`。理论上和排版完全同步，但在 `isRichText = false` 的 NSTextView 下表现异常（矩形缩成 pill 大小）。

**第三版（当前）：自定义 `CodeBlockLayoutManager: NSLayoutManager`**。手搭 TextKit 1 栈（`NSTextStorage → CodeBlockLayoutManager → NSTextContainer`，用 `NSTextView(frame:textContainer:)` 构造），override `drawBackground(forGlyphRange:at:)` 在 TextKit 自己的渲染管线内部画深色矩形。`at: origin` 自动包含 textContainerInset，`extraLineFragmentRect` 已计算好。**零时序问题。**

#### 键盘导航

- **Shift+Enter**（block 内）→ 换行扩展块（默认 NSTextView 行为 + typingAttr 继承）
- **Enter**（任何位置）→ 发送（和 block 外一致）
- **Down**（block 最后一行）→ `insertProseLineBelowBlock`：在 block 末尾插入 prose `\n`，cursor 跳到新行
- **Up**（block 首行第一字符）→ `insertProseLineAboveBlock`：在 block 起点插入 prose `\n`，cursor 跳到新行
- **Backspace**（block 首字符）→ `cancelCodeBlock`：删除 block range + 尾部 escape `\n`

`isCursorOnLastContentLineOfBlock` 从 cursor 向后搜索 `\n`：找不到 → 最后一行；找到的 `\n` 是 block 最后一个字符（anchor）→ 最后一行。`isCursorAtStartOfCodeBlock` 检查 cursor 位置有 code attr 而 cursor-1 没有。

Up/Down/Backspace 的 textStorage 操作用 `textStorage.insert(NSAttributedString)` / `textStorage.replaceCharacters(in:with:)` + 显式属性，**不走 `textView.replaceCharacters`**（`isRichText=false` 下属性继承不可靠 → block 被切碎）。

#### 语法高亮

regex-based，覆盖 Python/JS/TS/Swift/Go/Rust/Shell 常见 pattern：紫色 keywords（import/def/class/func/return...）、绿色 strings、橙色 numbers、灰色 comments（# //）、蓝色 builtins（print/len/str...）。在 `applyCodeBlockStyling` 的 `applySyntaxHighlighting` 中通过 `.foregroundColor` 属性实现。

#### 序列化

`payloadForSending()` → `resolvedTextForSending()` → `textWithCodeFencesApplied(to:)`。遍历 `codeBlocks`（按 location 排序），在每个 span 前后插入 ``` + language + `\n` 围栏。所有触发字符统一还原为 ASCII backtick。

## 实际执行

### 踩坑记录

1. **draw-time layout 时序**：最大的坑。`draw(_:)` 在 text mutation 同一帧被调用时，`NSLayoutManager` 的 line fragment rects 是旧的。`ensureLayout` 在 `draw()` 内部调用会引起反馈循环。最终解法：迁移到 `NSLayoutManager.drawBackground`（TextKit 内部调用，layout 100% current）。

2. **TextKit 2 回退**：macOS 12+ NSTextView 默认走 TextKit 2，`NSLayoutManager` override 不被调用。必须手搭 TextKit 1 栈：`NSTextStorage → CodeBlockLayoutManager → NSTextContainer → NSTextView(frame:textContainer:)`。

3. **NSTextBlock 在 isRichText=false 下失败**：`CodeBlockTextBlock.drawBackground` 被调用但 frame 缩成 pill 大小。原因可能是 `isRichText=false` 阻止了 NSTextBlock 的宽度扩展逻辑。

4. **textView.replaceCharacters 属性继承**：`isRichText=false` 下 `textView.replaceCharacters(in:with: String)` 对插入文本的属性继承行为不可预测——有时继承相邻代码属性而非 typingAttributes。改用 `textStorage.insert(NSAttributedString(string:attributes:))` 显式指定属性。

5. **anchor \n 的"多余一行"**：anchor `\n`（入口时插入的 code-attr 换行符）作为行终结符不创建额外空行，但 `isCursorOnLastContentLineOfBlock` 的旧逻辑（从后往前找 \n）把 anchor 当成内容分隔符 → 误判 cursor 位置。改为从 cursor 向后搜索。

6. **`parseFenceLine` 三字符同质校验**：`prefix.allSatisfy({ $0 == first })` 防止混合字符（如 `` `～` ``）误触发。

### 测试

22 个单测（`cmuxTests/Composer/CodeBlockTests.swift`）：
- `parseFenceLine`：14 tests（三种字符 × 有/无语言 × 边界条件）
- `textWithCodeFencesApplied`：5 tests（单块/多块/空块/无语言/含换行）
- payload 集成：2 tests（bash + code、code-only）
- 常量校验：1 test

Build tag `code-block` 产出 `cmux DEV code-block.app`。
