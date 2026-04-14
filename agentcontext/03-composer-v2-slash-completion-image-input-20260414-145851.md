# Composer V2：斜杠命令补全 + 图片输入

> 时间戳：2026-04-14 14:58  
> 基于 Composer V1（基础文本输入框）的增量功能。

---

## 一、需求

### 1. 斜杠命令补全

在 Composer 输入框中输入 `/` 时弹出补全菜单，类似 IDE 自动补全。

功能要求：
- 输入 `/` 后显示所有可用命令列表
- 支持实时过滤（继续输入字符缩小范围）
- 选中项旁边显示命令描述 tooltip
- 键盘导航：↑↓ 移动选中、Tab/Enter 确认、Esc 关闭弹窗
- 输入完整的已知命令时，文本变蓝色
- 命令来源：
  - 内置 Claude Code 命令（`/help`, `/compact`, `/clear` 等）
  - 已安装插件的 skill 命令（从 `~/.claude/plugins/installed_plugins.json` 解析）
  - 用户自定义命令（`~/.claude/commands/*.md`）
  - 项目自定义命令（`.claude/commands/*.md`）

### 2. 图片输入

支持在 Composer 中输入图片，采用"思路 B"——保存图片到临时文件，插入 shell-escaped 路径到文本。

功能要求：
- **粘贴图片**：⌘V 时检测剪贴板，如果有图片数据则保存为临时文件并插入路径
- **拖拽图片**：从 Finder 等拖入图片文件到 Composer
- **附件按钮**：Composer 左下角 `+` 按钮，打开 NSOpenPanel 选择图片文件

---

## 二、技术方案

### 2.1 斜杠命令——命令注册表（SlashCommandRegistry）

多源聚合，单例模式，后台线程加载，60 秒缓存：

```
内置命令（Resources/slash-commands.json）
    + 插件 skill（~/.claude/plugins/installed_plugins.json → {installPath}/skills/*/SKILL.md）
    + 用户命令（~/.claude/commands/*.md）
    + 项目命令（.claude/commands/*.md）
    ↓ 去重（优先级：项目 > 用户 > 插件 > 内置）
    ↓ 按名称排序
    → SlashCommandRegistry.shared.commands
```

插件 SKILL.md 解析 YAML frontmatter：
```yaml
---
name: brainstorming
description: "You MUST use this before any creative work..."
---
```

命名规则：`{plugin}:{skill}`（如 `superpowers:brainstorming`），同名时缩写（如 `skill-creator`）。

### 2.2 斜杠命令——补全弹窗（SlashCompletionView）

自定义 SwiftUI overlay（不用 NSPopover/NSPanel），定位在 Composer 文本框上方：
- 左侧：ScrollView + LazyVStack 命令列表（320pt 宽，300pt 最大高）
- 右侧：选中项描述 tooltip（深色背景，白色文字）
- `.regularMaterial` 背景 + 圆角 + 阴影

触发条件：文本以 `/` 开头且光标在命令 token 内（第一个空格之前）。

### 2.3 斜杠命令——文本变色

在 `textDidChange` 中通过 `NSTextStorage` 属性设置 `foregroundColor`：
- 识别行首的 `/command` token
- 完整命令 → `NSColor.systemBlue`
- IME 输入中（`hasMarkedText()`）跳过
- 用 `isProgrammaticMutation` 标志避免递归

### 2.4 Esc 键优先级

```
Esc pressed
 → IME 正在组合？ → 交给系统处理
 → 补全弹窗可见？ → 仅关闭弹窗
 → 否则 → dismiss Composer（原有行为）
```

### 2.5 图片粘贴

重写 `ComposerNSTextView.paste(_:)`：
1. 剪贴板有纯文本 → `super.paste()`
2. 剪贴板有图片 → `GhosttyPasteboardHelper.saveImageFileURLIfNeeded()` → 插入 escaped 路径
3. 否则 → `super.paste()`

### 2.6 图片拖拽

注册 `.fileURL`, `.png`, `.tiff` 拖拽类型。
`performDragOperation` 用 `TerminalImageTransferPlanner.prepare(pasteboard:, mode: .drop)` 处理。

### 2.7 附件按钮

`+` 按钮在 Composer 左下角，打开 `NSOpenPanel`（过滤图片类型），插入选中文件的 escaped 路径。

---

## 三、文件变更清单

### 新增
```
Sources/Composer/SlashCommandRegistry.swift    # 命令注册表（~190 LOC）
Sources/Composer/SlashCompletionView.swift     # 补全弹窗 UI（~90 LOC）
Resources/slash-commands.json                  # 22 条内置命令定义（可手动编辑）
docs/superpowers/specs/2026-04-14-composer-slash-completion-image-input-design.md
```

### 修改
```
Sources/Composer/ComposerState.swift           # +3 个 @Published 属性（补全状态）
Sources/Composer/ComposerInputView.swift       # 完整重写（+ 按钮、补全集成、图片粘贴/拖拽、文本变色、Esc 优先级）
GhosttyTabs.xcodeproj/project.pbxproj         # 注册 3 个新文件（2 源码 + 1 资源）
Resources/Localizable.xcstrings                # +2 本地化键（composer.attachImage.help, composer.attachImage.panelMessage，en+ja）
agentcontext/02-composer-feature.md            # 更新文档增加 V2 功能说明和测试步骤
```

---

## 四、实际执行的命令

### 4.1 探索阶段

```bash
# 查看插件文件结构
ls -la ~/.claude/plugins/
cat ~/.claude/plugins/installed_plugins.json
ls ~/.claude/commands/

# 查找所有插件 skill 文件
find ~/.claude/plugins/cache -name "SKILL.md" -maxdepth 5  # （用 Glob 工具）

# 查看 SKILL.md frontmatter 格式
head -5 ~/.claude/plugins/cache/claude-plugins-official/superpowers/5.0.7/skills/brainstorming/SKILL.md

# 查看自定义命令格式
head -5 ~/.claude/commands/release.md

# 查看现有 Composer 代码中的发送机制
grep "sendInput" Sources/Panels/TerminalPanel.swift

# 查看现有图片传输基础设施
grep "saveImageFileURLIfNeeded" Sources/GhosttyTerminalView.swift
grep "TerminalImageTransferPlanner" Sources/TerminalImageTransfer.swift

# 查看 pbxproj 中现有 Composer 文件注册方式
grep "ComposerState\|ComposerInputView" GhosttyTabs.xcodeproj/project.pbxproj
```

### 4.2 实现阶段

```bash
# 创建新文件（通过 Write 工具）
# - Resources/slash-commands.json
# - Sources/Composer/SlashCommandRegistry.swift
# - Sources/Composer/SlashCompletionView.swift

# 修改现有文件（通过 Edit 工具）
# - Sources/Composer/ComposerState.swift
# - Sources/Composer/ComposerInputView.swift（完整重写）
# - GhosttyTabs.xcodeproj/project.pbxproj（4 处 Edit）
# - Resources/Localizable.xcstrings（1 处 Edit）
# - agentcontext/02-composer-feature.md（1 处 Edit）
```

### 4.3 验证阶段

```bash
# 首次编译验证
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/cmux-composer-v2 build
# 结果：BUILD FAILED — frame(width:maxHeight:) 不是合法的 SwiftUI frame 调用

# 修复 SlashCompletionView.swift：拆分为两个 .frame() 调用
# .frame(width: ..., maxHeight: ...) → .frame(maxHeight: ...).frame(width: ...)

# 二次编译验证
xcodebuild ... build
# 结果：BUILD SUCCEEDED，无 warning

# 检查新文件是否有 warning
xcodebuild ... build 2>&1 | grep -E "warning:.*Composer|warning:.*Slash"
# 结果：无

# 最终 tagged build
./scripts/reload.sh --tag composer-v2
# 结果：BUILD SUCCEEDED
# App path: /Users/ansonlo/Library/Developer/Xcode/DerivedData/cmux-composer-v2/Build/Products/Debug/cmux DEV composer-v2.app
```

---

## 五、已知限制与后续优化

1. **命令列表静态性**：内置命令列表（`slash-commands.json`）需要手动维护。如果 Claude Code 新增命令，需要更新此文件。
2. **图片预览**：当前只插入路径文本，没有缩略图预览。后续可在路径旁显示小预览图。
3. **补全弹窗动画**：当前使用简单的 opacity + move transition，可以优化为更流畅的弹出动画。
4. **多行命令**：补全只检测文本开头的 `/`，如果用户在多行文本中间输入 `/`，不会触发补全。这是有意的设计（避免路径中的 `/` 误触发）。
5. **项目目录传入**：`SlashCommandRegistry.reloadIfNeeded(projectDirectory:)` 当前没有传入项目目录，需要在 `ComposerInputView.onAppear` 中获取当前终端的工作目录并传入。
