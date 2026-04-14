# Composer Slash Completion & Image Input

## Summary

Add two capabilities to the Composer input overlay:
1. **Slash command completion** with a custom popup, descriptions, and text coloring
2. **Image input** via paste, drag-drop, and an attachment button

## 1. Slash Command Completion

### 1.1 Command Registry (SlashCommandRegistry)

Multi-source aggregation, loaded once per Composer session on a background thread:

| Source | Path | Format |
|--------|------|--------|
| Built-in commands | `Resources/slash-commands.json` bundled in app | `[{name, description}]` JSON array |
| Plugin skills | `~/.claude/plugins/installed_plugins.json` → each plugin's `{installPath}/skills/*/SKILL.md` | YAML frontmatter: `name`, `description` |
| User custom commands | `~/.claude/commands/*.md` | Filename (sans `.md`) = command name; first `# heading` or first line = description |
| Project custom commands | `.claude/commands/*.md` (relative to cwd) | Same as above |

**Plugin skill naming**: `{plugin}:{skill}` (e.g., `superpowers:brainstorming`). If the plugin and skill names match (e.g., `skill-creator:skill-creator`), use the short form (`skill-creator`).

**Deduplication**: if the same command name appears in multiple sources, priority: project commands > user commands > plugins > built-in.

**Caching**: results stored in `SlashCommandRegistry.shared`. Reloaded when Composer is shown (debounced, max once per 60s).

### 1.2 Completion Popup (SlashCompletionView)

Custom SwiftUI overlay positioned above the Composer text field (not an NSPopover or NSPanel).

**Trigger**: when the text starts with `/` and the cursor is still within the command token (before any space).

**UI**:
- Rounded rectangle with `.regularMaterial` background, 8pt corner radius, shadow
- Left: scrollable list of matching commands (max height 300pt, max width 360pt)
- Right: description tooltip for selected item (dark background, white text, rounded corners)
- Selected item has light background highlight

**Keyboard**:
- Up/Down: move selection (wraps around)
- Tab or Enter: insert selected command, close popup
- Esc: close popup only (do NOT dismiss Composer)
- Typing: live filter

**Dismissal**: popup closes on blur, space after command, or Esc.

### 1.3 Text Coloring (ComposerTextHighlighter)

When a complete recognized command is typed at line start (e.g., `/compact`), the `/command` token turns blue (`.systemBlue`).

Implementation: modify `NSTextStorage` attributes in `textDidChange()`. Skip during IME composition (`hasMarkedText()`). Use `isProgrammaticMutation` flag to avoid recursion.

## 2. Image Input

All image input uses **approach B**: save image to temp file, insert shell-escaped path into text.

### 2.1 Paste

Override `ComposerNSTextView.paste(_:)`:
- If clipboard has text → `super.paste()`
- If clipboard has image → `GhosttyPasteboardHelper.saveImageFileURLIfNeeded()` → insert escaped path
- Else → `super.paste()`

### 2.2 Drag & Drop

Register `ComposerNSTextView` for `.fileURL`, `.png`, `.tiff` drag types. In `performDragOperation`, use `TerminalImageTransferPlanner.prepare(pasteboard:mode:.drop)` to resolve content, insert file paths.

### 2.3 Attachment Button (+)

A `+` icon button at the bottom-left of the Composer. Opens `NSOpenPanel` filtered to image types. Inserts shell-escaped paths of selected files.

## 3. File Structure

```
Sources/Composer/
  ComposerState.swift                  (modify: add completion visibility state)
  ComposerInputView.swift              (modify: add + button, popup, keyboard intercept)
  SlashCommandRegistry.swift           (new: command discovery + caching)
  SlashCompletionView.swift            (new: popup UI)
Resources/
  slash-commands.json                  (new: built-in command definitions)
```

## 4. Esc Key Priority

When completion popup is visible: Esc closes popup only.
When popup is hidden: Esc dismisses Composer (existing behavior).

## 5. Localization

New strings: `composer.attachImage.label`, `composer.attachImage.help`.
