# 03 - Composer V2: 斜杠补全 + 图片输入

> 对应原文：`agentcontext/03-composer-v2-slash-completion-image-input-20260414-145851.md`
> 时间戳：2026-04-14 14:58

## 需求

V1 基础文本框稳定后追加两组功能：

**斜杠命令补全**：在 Composer 输入 `/` 时弹出补全菜单（类 IDE 自动补全），实时过滤、显示命令描述、↑↓ 导航、Tab/Enter 确认、Esc 关闭弹窗、识别完整命令时变蓝。命令来源四种：内置 Claude Code 命令（`/help`, `/compact`, `/clear` 等）、`~/.claude/plugins/installed_plugins.json` 解析的插件 skill、`~/.claude/commands/*.md` 用户自定义、`.claude/commands/*.md` 项目自定义。

**图片输入**：采用"思路 B"——保存图片到临时文件，在文本中插入 shell-escaped 路径。三种入口：⌘V 粘贴检测剪贴板有图就保存、从 Finder 拖入、Composer 左下角 `+` 按钮打开 NSOpenPanel。

## 技术方案

**SlashCommandRegistry（~190 LOC，单例）**：后台线程多源聚合，60 秒缓存。优先级 项目 > 用户 > 插件 > 内置，按名称排序去重。插件 SKILL.md 解析 YAML frontmatter 取 `name` 和 `description`，命名 `{plugin}:{skill}`（如 `superpowers:brainstorming`），同名时缩写。自定义命令用文件名（去 `.md`）为名，第一个 `# heading` 为描述。

**SlashCompletionView（~90 LOC）**：自定义 SwiftUI overlay（不用 NSPopover/NSPanel），定位在 Composer 文本框上方。左侧 ScrollView+LazyVStack 命令列表（320pt 宽，300pt 最大高），右侧选中项描述 tooltip（深色背景白文字），`.regularMaterial` 背景 + 圆角阴影。触发条件：文本以 `/` 开头且光标在第一个空格之前。

**文本变色**：`textDidChange` 中通过 `NSTextStorage` 属性设置 `foregroundColor`，识别完整命令变 `NSColor.systemBlue`。`hasMarkedText()` 跳过 IME 中状态，`isProgrammaticMutation` 标志避免递归。

**Esc 优先级**：IME 组合中 → 系统处理；补全弹窗可见 → 仅关弹窗；否则 → dismiss Composer。

**图片粘贴/拖拽**：重写 `ComposerNSTextView.paste(_:)` 检测剪贴板顺序（文本→图片→默认）；注册 `.fileURL/.png/.tiff` 拖拽类型，`performDragOperation` 用现成的 `TerminalImageTransferPlanner.prepare(pasteboard:, mode: .drop)` 处理。

## 实际执行

新增三个文件（SlashCommandRegistry.swift、SlashCompletionView.swift、Resources/slash-commands.json 含 22 条内置命令），完整重写 ComposerInputView（+ 按钮、补全集成、图片粘贴/拖拽、文本变色、Esc 优先级），ComposerState 加 3 个 @Published 属性，pbxproj 注册 3 文件，Localizable 加 2 键（en+ja）。首次编译失败：`frame(width:maxHeight:)` 不是合法的 SwiftUI 调用，拆成两个 `.frame()` 链式调用后 BUILD SUCCEEDED 无 warning。已知限制：内置命令列表静态需手动维护、暂无图片缩略图预览、`reloadIfNeeded(projectDirectory:)` 当前没传入项目目录需在 `onAppear` 补上。
