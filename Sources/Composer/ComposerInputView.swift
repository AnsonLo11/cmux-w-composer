import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerInputView: View {
    @ObservedObject var composerState: ComposerState
    /// Send text to terminal input (Enter). Text appears in CC but is not submitted.
    let onSend: (String) -> Void
    /// Send text AND submit to CC (Cmd+Enter). Appends a newline so CC processes the prompt.
    let onSendAndSubmit: (String) -> Void
    let onDismiss: () -> Void
    let onTextViewBecameFirstResponder: () -> Void
    /// Supplies the current working directory for `@`-file completion.
    /// Nil when no cwd is known (fall back to listing nothing).
    var cwdProvider: (() -> String?)? = nil

    private static let defaultHeight: CGFloat = 80
    private static let minAllowedHeight: CGFloat = 50
    private static let maxAllowedHeight: CGFloat = 400

    @State private var composerHeight: CGFloat = ComposerInputView.defaultHeight
    @GestureState private var dragOffset: CGFloat = 0

    private var effectiveHeight: CGFloat {
        let h = composerHeight - dragOffset
        return min(max(h, Self.minAllowedHeight), Self.maxAllowedHeight)
    }

    var body: some View {
        // .leading alignment so the completion popup (narrower than the
        // composer card) hugs the card's left edge instead of centering.
        VStack(alignment: .leading, spacing: 0) {
            // Slash completion popup (above the composer card)
            if composerState.showCompletion {
                let filtered = SlashCommandRegistry.shared.matching(composerState.completionFilter)
                if !filtered.isEmpty {
                    CompletionPopupView(
                        items: filtered,
                        selectedIndex: $composerState.completionSelectedIndex,
                        onSelect: { command in
                            insertCompletedCommand(command)
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            } else if composerState.showFileCompletion,
                      !composerState.fileCompletionItems.isEmpty {
                CompletionPopupView(
                    items: composerState.fileCompletionItems,
                    selectedIndex: $composerState.fileCompletionSelectedIndex,
                    onSelect: { entry in
                        insertCompletedFile(entry)
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
            // Composer card
            VStack(spacing: 0) {
                // Drag handle for resizing
                composerDragHandle

                // Text input area. The bash-mode ❯ prompt is drawn *inside*
                // ComposerNSTextView (see drawBashPrompt) so it shares the
                // NSTextView's font, baseline, and left inset — avoiding the
                // two-coordinate-system alignment drift we used to get from a
                // SwiftUI Text sitting next to the NSTextView.
                HStack(alignment: .top, spacing: 0) {
                    ComposerTextViewRepresentable(
                        composerState: composerState,
                        onSend: {
                            let content = composerState.text
                            guard !content.isEmpty else { return }
                            onSend(content)
                        },
                        onSendAndSubmit: {
                            let content = composerState.text
                            guard !content.isEmpty else { return }
                            onSendAndSubmit(content)
                        },
                        onDismiss: onDismiss,
                        onBecomeFirstResponder: onTextViewBecameFirstResponder,
                        onInsertCommand: { command in
                            insertCompletedCommand(command)
                        },
                        onInsertFile: { entry in
                            insertCompletedFile(entry)
                        },
                        cwdProvider: cwdProvider
                    )
                    .frame(height: effectiveHeight)
                }

                // Bottom toolbar: + button on left, send button on right
                HStack(spacing: 0) {
                    Button(action: openFilePicker) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 10)
                    .safeHelp(String(
                        localized: "composer.attachImage.help",
                        defaultValue: "Attach image"
                    ))

                    Spacer()

                    // Send button (same as Enter: send to terminal input)
                    Button(action: {
                        let content = composerState.text
                        guard !content.isEmpty else { return }
                        onSendAndSubmit(content)
                    }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(sendButtonForeground)
                    }
                    .buttonStyle(.plain)
                    .disabled(composerState.text.isEmpty)
                    .padding(.trailing, 10)
                    .safeHelp(String(
                        localized: "composer.send.help",
                        defaultValue: "Send (⌘Enter)"
                    ))
                }
                .padding(.vertical, 6)
            }
            .background(composerBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        composerState.bashMode
                            ? Self.bashAccent.opacity(0.55)
                            : Color.primary.opacity(0.1),
                        lineWidth: composerState.bashMode ? 1.5 : 1
                    )
            )
            .shadow(
                color: composerState.bashMode
                    ? Self.bashAccent.opacity(0.35)
                    : .black.opacity(0.06),
                radius: composerState.bashMode ? 10 : 3,
                y: 1
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .animation(.easeInOut(duration: 0.22), value: composerState.bashMode)
        }
        .onAppear {
            SlashCommandRegistry.shared.reloadIfNeeded()
        }
    }

    // MARK: - Bash-mode visual chrome

    /// Accent color used for the ❯ prompt, glow border, and drop shadow in
    /// bash mode. Mint/cyan (#2EE59D) to read as "terminal" without clashing
    /// with standard SwiftUI blues.
    private static let bashAccent = Color(
        red: 0x2E / 255.0, green: 0xE5 / 255.0, blue: 0x9D / 255.0
    )

    @ViewBuilder
    private var composerBackground: some View {
        if composerState.bashMode {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0x0D / 255.0, green: 0x11 / 255.0, blue: 0x17 / 255.0), // #0D1117
                        Color(red: 0x16 / 255.0, green: 0x1B / 255.0, blue: 0x22 / 255.0)  // #161B22
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // Subtle noise overlay so the flat gradient doesn't look plastic.
                Canvas { ctx, size in
                    let count = Int(size.width * size.height / 900)
                    for _ in 0..<count {
                        let x = Double.random(in: 0..<size.width)
                        let y = Double.random(in: 0..<size.height)
                        let alpha = Double.random(in: 0.015...0.05)
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: 0.7, height: 0.7)),
                            with: .color(.white.opacity(alpha))
                        )
                    }
                }
                .allowsHitTesting(false)
            }
            .transition(.opacity)
        } else {
            Color.clear.background(.background.opacity(0.97))
        }
    }

    private var sendButtonForeground: Color {
        if composerState.text.isEmpty {
            return composerState.bashMode
                ? Self.bashAccent.opacity(0.3)
                : Color.primary.opacity(0.15)
        } else {
            return composerState.bashMode
                ? Self.bashAccent.opacity(0.85)
                : Color.primary.opacity(0.5)
        }
    }

    // MARK: - Drag handle

    private var composerDragHandle: some View {
        VStack(spacing: 0) {
            // Invisible hit area + visible handle line
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary.opacity(0.15))
                .frame(width: 36, height: 3)
                .padding(.top, 6)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .updating($dragOffset) { value, state, _ in
                    state = value.translation.height
                }
                .onEnded { value in
                    let newHeight = composerHeight - value.translation.height
                    composerHeight = min(max(newHeight, Self.minAllowedHeight), Self.maxAllowedHeight)
                }
        )
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Actions

    private func insertCompletedCommand(_ command: SlashCommand) {
        composerState.text = "/\(command.name) "
        composerState.showCompletion = false
    }

    private func insertCompletedFile(_ entry: FileEntry) {
        let ns = composerState.text as NSString
        let range = composerState.fileCompletionTokenRange
        let escaped = GhosttyPasteboardHelper.escapeForShell(entry.relativePath)
        let replacement = "\(escaped) "
        // Guard the stored range is still valid (text may have shifted if the
        // user kept typing; the popup closes on every keystroke that changes
        // the token, so in practice this is current).
        guard range.location >= 0,
              range.location + range.length <= ns.length else {
            composerState.showFileCompletion = false
            return
        }
        let updated = ns.replacingCharacters(in: range, with: replacement)
        composerState.text = updated
        composerState.showFileCompletion = false
        composerState.fileCompletionItems = []
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .gif]
        if let webP = UTType("public.webp") {
            panel.allowedContentTypes.append(webP)
        }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(
            localized: "composer.attachImage.panelMessage",
            defaultValue: "Select images to attach"
        )
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let marker = composerState.addImage(url: url)
            let prefix = composerState.text.isEmpty || composerState.text.hasSuffix(" ") ? "" : " "
            composerState.text += prefix + marker + " "
        }
    }
}

// MARK: - Code block attribute key

extension NSAttributedString.Key {
    /// Marks a run of characters as belonging to a code block. Value is
    /// the language identifier string (possibly empty for unlabeled
    /// blocks). Used both to paint the gray background in the
    /// NSTextView and to rebuild `ComposerState.codeBlocks` from the
    /// textStorage after edits.
    static let cmuxCodeBlock = NSAttributedString.Key("cmuxCodeBlock")
}

// MARK: - Code block layout manager

/// Custom `NSLayoutManager` that draws full-width dark rounded-rect
/// backgrounds behind code-block paragraphs. `drawBackground` is called
/// by TextKit during its own rendering pass — layout is guaranteed to be
/// current, `origin` includes textContainerInset, and
/// `extraLineFragmentRect` has already been computed.
///
/// This replaces the old `ComposerNSTextView.drawCodeBlockBackgrounds`
/// override which suffered from timing issues (stale layout after text
/// mutations).
private final class CodeBlockLayoutManager: NSLayoutManager {

    private static let bg = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x2E / 255.0, alpha: 1)
            : NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x2E / 255.0, alpha: 1)
    }
    private static let cornerRadius: CGFloat = 6
    private static let xPad: CGFloat = 4
    private static let yPad: CGFloat = 6

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        guard let textStorage = textStorage,
              let textContainer = textContainers.first else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard charRange.length > 0 else { return }

        // Collect contiguous code-block attribute runs, merge their line
        // fragment rects into one rounded rect per block.
        let containerWidth = textContainer.containerSize.width

        textStorage.enumerateAttribute(.cmuxCodeBlock, in: charRange) { value, range, _ in
            guard value != nil else { return }
            let blockGlyphRange = self.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil
            )
            guard blockGlyphRange.length > 0 else { return }

            var blockRect = CGRect.null
            self.enumerateLineFragments(forGlyphRange: blockGlyphRange) { lineRect, _, _, _, _ in
                let fullWidth = CGRect(
                    x: 0, y: lineRect.origin.y,
                    width: containerWidth, height: lineRect.height
                )
                blockRect = blockRect.isNull ? fullWidth : blockRect.union(fullWidth)
            }

            // If the block ends at the document end with \n, include
            // the extra line fragment (the empty line the cursor sits
            // on) so Shift+Enter visually extends the block immediately.
            let ns = textStorage.string as NSString
            if NSMaxRange(range) == ns.length,
               range.length > 0,
               ns.character(at: NSMaxRange(range) - 1) == 0x0A {
                let extra = self.extraLineFragmentRect
                if extra.height > 0 {
                    let fw = CGRect(x: 0, y: extra.origin.y, width: containerWidth, height: extra.height)
                    blockRect = blockRect.isNull ? fw : blockRect.union(fw)
                }
            }

            guard !blockRect.isNull else { return }

            // Offset by `origin` (includes textContainerInset) and add
            // padding for visual breathing room.
            let drawRect = CGRect(
                x: blockRect.origin.x + origin.x - Self.xPad,
                y: blockRect.origin.y + origin.y - Self.yPad,
                width: blockRect.width + Self.xPad * 2,
                height: blockRect.height + Self.yPad * 2
            )
            Self.bg.setFill()
            NSBezierPath(
                roundedRect: drawRect,
                xRadius: Self.cornerRadius,
                yRadius: Self.cornerRadius
            ).fill()
        }
    }
}

// MARK: - NSTextView wrapper

/// An NSTextView with full IME, multi-line editing, and mouse cursor support.
/// Cmd+Enter sends text; Escape dismisses; slash commands trigger completion.
private struct ComposerTextViewRepresentable: NSViewRepresentable {
    @ObservedObject var composerState: ComposerState
    let onSend: () -> Void
    let onSendAndSubmit: () -> Void
    let onDismiss: () -> Void
    let onBecomeFirstResponder: () -> Void
    let onInsertCommand: (SlashCommand) -> Void
    let onInsertFile: (FileEntry) -> Void
    let cwdProvider: (() -> String?)?

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextViewRepresentable
        var isProgrammaticMutation = false
        /// Tracks which ComposerState instance we last focused for.
        /// When a new state appears (Composer reopened), we re-focus.
        var lastFocusedStateID: ObjectIdentifier?

        init(parent: ComposerTextViewRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticMutation else { return }
            guard let textView = notification.object as? NSTextView else { return }
            let state = parent.composerState
            let newText = textView.string

            // Bash-mode enter: a lone '!' or '！' in a non-bash composer flips
            // us into bash visual theme and clears the text. The triggering
            // character becomes the prompt indicator, not part of the command.
            if !state.bashMode,
               !textView.hasMarkedText(),
               ComposerState.shouldEnterBashMode(text: newText) {
                state.bashMode = true
                isProgrammaticMutation = true
                textView.string = ""
                state.text = ""
                isProgrammaticMutation = false
                state.showCompletion = false
                state.showFileCompletion = false
                return
            }

            // Bash-mode exit: backspacing to empty drops us back to normal.
            if state.bashMode, newText.isEmpty {
                state.bashMode = false
            }

            state.text = newText
            // Reset history navigation when user types (not when browsing history)
            state.resetHistoryNavigation()

            // "/code " trigger: when the user types a space after "/code"
            // anywhere in the text, enter code block at that position.
            if !textView.hasMarkedText(),
               attemptSlashCodeTrigger(textView: textView, trailingChar: " ") {
                return
            }

            updateSlashCompletion(text: newText)
            updateFileCompletion(textView: textView)
            applySlashCommandHighlighting(textView: textView)
            applyCodeBlockStyling(textView: textView)
            syncCodeBlocksFromTextStorage(textView: textView)
            updateTypingAttributesForCursor(textView: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Skip while the fence-transition is rewriting the document —
            // it sets typingAttributes explicitly and our neighbor-based
            // inference would fight it (empty block has no chars to key
            // off of).
            guard !isProgrammaticMutation else { return }
            guard let textView = notification.object as? NSTextView else { return }
            updateTypingAttributesForCursor(textView: textView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onBecomeFirstResponder()
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            // Escape: close completion popup first, then dismiss Composer
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if textView.hasMarkedText() { return false }
                if parent.composerState.showCompletion {
                    parent.composerState.showCompletion = false
                    return true
                }
                if parent.composerState.showFileCompletion {
                    parent.composerState.showFileCompletion = false
                    return true
                }
                parent.onDismiss()
                return true
            }
            // Bash-mode Tab: when no popup is visible, open file completion
            // using the word-before-cursor as filter.
            if parent.composerState.bashMode,
               !parent.composerState.showFileCompletion,
               !parent.composerState.showCompletion,
               commandSelector == #selector(NSResponder.insertTab(_:)) {
                triggerBashTabCompletion(textView: textView)
                return true
            }
            // File completion keyboard nav (mirrors slash completion)
            if parent.composerState.showFileCompletion {
                let items = parent.composerState.fileCompletionItems
                if commandSelector == #selector(NSResponder.moveUp(_:)) {
                    if !items.isEmpty {
                        let idx = parent.composerState.fileCompletionSelectedIndex
                        parent.composerState.fileCompletionSelectedIndex =
                            (idx - 1 + items.count) % items.count
                    }
                    return true
                }
                if commandSelector == #selector(NSResponder.moveDown(_:)) {
                    if !items.isEmpty {
                        let idx = parent.composerState.fileCompletionSelectedIndex
                        parent.composerState.fileCompletionSelectedIndex =
                            (idx + 1) % items.count
                    }
                    return true
                }
                if commandSelector == #selector(NSResponder.insertTab(_:)) {
                    if let entry = items[safe: parent.composerState.fileCompletionSelectedIndex] {
                        parent.onInsertFile(entry)
                    }
                    return true
                }
                if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    if let entry = items[safe: parent.composerState.fileCompletionSelectedIndex] {
                        parent.onInsertFile(entry)
                    }
                    return true
                }
            }
            // Up/Down arrow: navigate completion list when visible
            if parent.composerState.showCompletion {
                let filtered = SlashCommandRegistry.shared.matching(parent.composerState.completionFilter)
                if commandSelector == #selector(NSResponder.moveUp(_:)) {
                    if !filtered.isEmpty {
                        let idx = parent.composerState.completionSelectedIndex
                        parent.composerState.completionSelectedIndex = (idx - 1 + filtered.count) % filtered.count
                    }
                    return true
                }
                if commandSelector == #selector(NSResponder.moveDown(_:)) {
                    if !filtered.isEmpty {
                        let idx = parent.composerState.completionSelectedIndex
                        parent.composerState.completionSelectedIndex = (idx + 1) % filtered.count
                    }
                    return true
                }
                // Tab: accept selected completion
                if commandSelector == #selector(NSResponder.insertTab(_:)) {
                    if let cmd = filtered[safe: parent.composerState.completionSelectedIndex] {
                        parent.onInsertCommand(cmd)
                    }
                    return true
                }
                // Enter (plain): accept selected completion when popup is visible
                if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    if let cmd = filtered[safe: parent.composerState.completionSelectedIndex] {
                        parent.onInsertCommand(cmd)
                    }
                    return true
                }
            }
            // Code-block navigation: Up at block start → insert prose
            // line above; Down at last content line → jump out of block.
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if isCursorAtStartOfCodeBlock(textView: textView) {
                    insertProseLineAboveBlock(textView: textView)
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if let block = codeBlockContainingCursor(textView: textView),
                   isCursorOnLastContentLineOfBlock(textView: textView, block: block.range) {
                    insertProseLineBelowBlock(textView: textView, block: block.range)
                    return true
                }
            }
            // Code-block navigation: Backspace at block start → cancel block.
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                if isCursorAtStartOfCodeBlock(textView: textView) {
                    cancelCodeBlock(textView: textView)
                    return true
                }
            }
            // Up/Down when text is empty: browse send history
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                let state = parent.composerState
                if state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || state.historyIndex >= 0 {
                    if let historyText = state.historyUp() {
                        state.text = historyText
                        return true
                    }
                }
                return false // let NSTextView handle cursor movement
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                let state = parent.composerState
                if state.historyIndex >= 0 {
                    if let historyText = state.historyDown() {
                        state.text = historyText
                        return true
                    }
                }
                return false
            }
            // Enter key handling (when completion popup is NOT visible):
            // Shift+Enter on a fence line → toggle code-block mode
            // Shift+Enter elsewhere → insert newline (default behavior)
            // Plain Enter → send text to terminal
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                    // Fence triggers take priority: Shift+Enter on a line
                    // that is exactly a fence pattern (``` / ～～～ / ···
                    // optionally followed by a language tag) enters or
                    // exits code-block mode instead of inserting a newline.
                    if attemptCodeBlockFenceTransition(textView: textView) {
                        return true
                    }
                    return false // let NSTextView insert newline
                }
                // "/code" + Enter: enter code-block instead of sending.
                if attemptSlashCodeTrigger(textView: textView, trailingChar: nil) {
                    return true
                }
                parent.onSend()
                return true
            }
            // Cmd+Enter is handled via performKeyEquivalent on the scroll view subclass
            return false
        }

        // MARK: - Image attachment

        func insertImageAttachment(in textView: NSTextView, imageURL: URL, marker: String) {
            guard let textStorage = textView.textStorage else { return }

            let originalImage = NSImage(contentsOf: imageURL)

            // Create a tiny color swatch (14x14) sampled from the image
            let swatchSize: CGFloat = 14
            let swatch = NSImage(size: NSSize(width: swatchSize, height: swatchSize))
            swatch.lockFocus()
            if let img = originalImage {
                img.draw(
                    in: NSRect(x: 0, y: 0, width: swatchSize, height: swatchSize),
                    from: .zero, operation: .sourceOver, fraction: 1.0
                )
            } else {
                NSColor.systemGray.setFill()
                NSRect(x: 0, y: 0, width: swatchSize, height: swatchSize).fill()
            }
            swatch.unlockFocus()

            // Build the inline pill cell
            let cell = ComposerImageAttachmentCell(
                swatch: swatch, marker: marker, fullImageURL: imageURL
            )

            let attachment = NSTextAttachment()
            attachment.attachmentCell = cell

            // Insert space + attachment + space
            let insertionPoint = textView.selectedRange()
            isProgrammaticMutation = true
            let prefix = textView.string.isEmpty || textView.string.hasSuffix(" ") ? "" : " "
            if !prefix.isEmpty {
                textStorage.insert(NSAttributedString(string: prefix), at: insertionPoint.location)
            }
            let attachPos = insertionPoint.location + prefix.count
            let attachStr = NSAttributedString(attachment: attachment)
            textStorage.insert(attachStr, at: attachPos)
            textStorage.insert(NSAttributedString(string: " "), at: attachPos + 1)
            isProgrammaticMutation = false

            // Sync text state (attachment char is U+FFFC in the string)
            parent.composerState.text = textView.string
            textView.setSelectedRange(NSRange(location: attachPos + 2, length: 0))
        }

        // MARK: - File completion logic

        /// Bash-mode Tab: list cwd entries matching the word at the cursor.
        /// Mirrors the `@`-triggered popup but uses the last whitespace-
        /// separated word as the filter, so `cat READ<Tab>` finds README.md.
        func triggerBashTabCompletion(textView: NSTextView) {
            let state = parent.composerState
            guard let match = FileTokenDetector.detectWordBeforeCursor(
                in: textView.string,
                cursorOffset: textView.selectedRange().location
            ) else { return }
            guard let cwd = parent.cwdProvider?(), !cwd.isEmpty else { return }
            let entries = FileCompletionProvider.list(cwd: cwd, filter: match.word)
            guard !entries.isEmpty else { return }
            state.fileCompletionTokenRange = match.range
            state.fileCompletionFilter = match.word
            state.fileCompletionItems = entries
            state.fileCompletionSelectedIndex = 0
            state.showFileCompletion = true
        }

        /// Detect `@filter` at the cursor and refresh the file popup items.
        /// Slash completion takes priority — if a slash popup is showing, the
        /// file popup stays hidden.
        func updateFileCompletion(textView: NSTextView) {
            let state = parent.composerState
            if state.showCompletion {
                state.showFileCompletion = false
                state.fileCompletionItems = []
                return
            }
            guard let match = FileTokenDetector.detectAtToken(
                in: textView.string,
                cursorOffset: textView.selectedRange().location
            ) else {
                state.showFileCompletion = false
                state.fileCompletionItems = []
                return
            }
            // Resolve cwd; if none, show empty popup (effectively closed).
            guard let cwd = parent.cwdProvider?(), !cwd.isEmpty else {
                state.showFileCompletion = false
                state.fileCompletionItems = []
                return
            }
            let entries = FileCompletionProvider.list(cwd: cwd, filter: match.filter)
            state.fileCompletionTokenRange = match.range
            state.fileCompletionFilter = match.filter
            state.fileCompletionItems = entries
            state.fileCompletionSelectedIndex = 0
            state.showFileCompletion = !entries.isEmpty
        }

        // MARK: - /code trigger

        /// Detect "/code" immediately before the cursor (optionally
        /// followed by `trailingChar` such as a space). When found,
        /// delete the trigger text and enter code-block mode at that
        /// position. Returns true when handled.
        ///
        /// - `trailingChar == " "`: called from textDidChange after the
        ///   user typed a space (the space is already in the text).
        /// - `trailingChar == nil`: called from doCommandBy when the user
        ///   presses Enter (the Enter has NOT been inserted yet).
        func attemptSlashCodeTrigger(textView: NSTextView, trailingChar: Character?) -> Bool {
            guard let textStorage = textView.textStorage else { return false }
            let ns = textView.string as NSString
            let cursor = textView.selectedRange().location
            // Build the pattern we're looking for just before the cursor.
            let pattern = "/code" + (trailingChar.map(String.init) ?? "")
            let patLen = (pattern as NSString).length
            guard cursor >= patLen else { return false }
            let probeRange = NSRange(location: cursor - patLen, length: patLen)
            guard ns.substring(with: probeRange) == pattern else { return false }
            // Ensure /code is not inside an existing code block.
            if probeRange.location > 0,
               textStorage.attribute(
                   .cmuxCodeBlock, at: probeRange.location, effectiveRange: nil
               ) != nil {
                return false
            }

            // Reuse the fence-transition machinery. Delete "/code " (or
            // "/code") and enter code block at that position.
            let monoFont = NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize, weight: .regular
            )
            let proseAttrs: [NSAttributedString.Key: Any] = [.font: monoFont]
            let codeAttrs: [NSAttributedString.Key: Any] = [
                .cmuxCodeBlock: "",
                .font: monoFont,
            ]

            isProgrammaticMutation = true

            textStorage.replaceCharacters(
                in: probeRange,
                with: NSAttributedString(string: "", attributes: proseAttrs)
            )
            let insertPos = probeRange.location
            // Anchor \n with code attr for immediate dark rect.
            textStorage.insert(
                NSAttributedString(string: "\n", attributes: codeAttrs),
                at: insertPos
            )
            // Trailing prose \n for escape.
            let postNS = textView.string as NSString
            let afterAnchor = insertPos + 1
            let needsTrailingNL: Bool = {
                if afterAnchor >= postNS.length { return true }
                return postNS.character(at: afterAnchor) != 0x0A
            }()
            if needsTrailingNL {
                textStorage.insert(
                    NSAttributedString(string: "\n", attributes: proseAttrs),
                    at: afterAnchor
                )
            }
            textView.setSelectedRange(NSRange(location: insertPos, length: 0))
            textView.typingAttributes = codeAttrs

            isProgrammaticMutation = false
            applyCodeBlockStyling(textView: textView)
            syncCodeBlocksFromTextStorage(textView: textView)
            applySlashCommandHighlighting(textView: textView)
            parent.composerState.text = textView.string
            parent.composerState.showCompletion = false
            parent.composerState.showFileCompletion = false
            return true
        }

        // MARK: - Code blocks

        /// Examine the current line. If it is a fence trigger line (``` /
        /// ～～～ / ··· optionally followed by a language tag), consume
        /// the Enter and either enter or exit code-block mode at the
        /// cursor. Returns true when the transition fired so the caller
        /// swallows the Enter.
        func attemptCodeBlockFenceTransition(textView: NSTextView) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            guard let textStorage = textView.textStorage else { return false }
            let ns = textView.string as NSString
            let cursor = textView.selectedRange().location
            guard cursor <= ns.length else { return false }

            // The "current line" is everything from the previous newline
            // (exclusive) up to the cursor. We require cursor = end of
            // line (no trailing text to the right of the fence on the
            // same line), so the behavior is unambiguous.
            let lineStart: Int = {
                if cursor == 0 { return 0 }
                let beforeCursor = NSRange(location: 0, length: cursor)
                let nlRange = ns.rangeOfCharacter(
                    from: .newlines,
                    options: .backwards,
                    range: beforeCursor
                )
                return nlRange.location == NSNotFound ? 0 : nlRange.location + nlRange.length
            }()
            // Require cursor to be at the end of the line: either EOF or
            // the next character is a newline.
            if cursor < ns.length {
                let next = ns.character(at: cursor)
                let isNL = CharacterSet.newlines.contains(
                    Unicode.Scalar(next) ?? Unicode.Scalar(0)
                )
                guard isNL else { return false }
            }
            let lineText = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
            guard let language = ComposerState.parseFenceLine(lineText) else {
                return false
            }

            // Decide whether cursor is inside or outside an existing code
            // block by inspecting the attribute just before `lineStart`
            // (the fence line itself is plain prose — the block, if any,
            // lives in the lines above it).
            let inBlock: Bool
            if lineStart > 0,
               textStorage.attribute(.cmuxCodeBlock, at: lineStart - 1, effectiveRange: nil) != nil {
                inBlock = true
            } else {
                inBlock = false
            }

            let monoFont = NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize, weight: .regular
            )
            let proseAttrs: [NSAttributedString.Key: Any] = [.font: monoFont]
            let codeAttrs: [NSAttributedString.Key: Any] = [
                .cmuxCodeBlock: language,
                .font: monoFont,
            ]

            // Wrap the mutation + explicit typingAttributes in the
            // programmatic-mutation flag so the textDidChange delegate
            // doesn't re-enter completion/bash detection. We intentionally
            // do NOT call updateTypingAttributesForCursor afterward — that
            // helper derives typingAttr from surrounding characters, but
            // when we've just entered an empty block the block has zero
            // chars so neighbor-based inference would pick the wrong side.
            // The explicit assignment below is the source of truth.
            isProgrammaticMutation = true

            let fenceLineRange = NSRange(location: lineStart, length: cursor - lineStart)

            if inBlock {
                // EXIT. Structure before transition (cursor at end of fence):
                //   ...<code content>\n```<cursor>
                // The \n at (lineStart - 1) and the ``` chars both carry
                // the code attribute (they were typed inside the block).
                //
                // Target after transition:
                //   ...<code content>\n<cursor>
                // where the code block now ends at `<code content>` and
                // the \n at (lineStart - 1) is prose (serves as the
                // escape-below blank line between block and cursor).
                textStorage.replaceCharacters(
                    in: fenceLineRange,
                    with: NSAttributedString(string: "", attributes: proseAttrs)
                )
                if lineStart > 0 {
                    let boundary = NSRange(location: lineStart - 1, length: 1)
                    textStorage.removeAttribute(.cmuxCodeBlock, range: boundary)
                    textStorage.removeAttribute(.backgroundColor, range: boundary)
                }
                // Ensure a trailing prose \n exists so the user has a
                // concrete blank line to land the cursor on.
                let post = textView.string as NSString
                let needsTrailingNL: Bool = {
                    if lineStart >= post.length { return true }
                    let c = post.character(at: lineStart)
                    return c != 0x0A && c != 0x0D
                }()
                if needsTrailingNL {
                    textStorage.insert(
                        NSAttributedString(string: "\n", attributes: proseAttrs),
                        at: lineStart
                    )
                }
                let finalCursor = lineStart + (needsTrailingNL ? 1 : 0)
                textView.setSelectedRange(NSRange(location: finalCursor, length: 0))
                textView.typingAttributes = proseAttrs
            } else {
                // ENTER. Delete the fence line and insert an anchor \n
                // with .cmuxCodeBlock so the dark rect renders
                // immediately (the \n gives a real glyph / line
                // fragment for the layout manager to draw against).
                // A trailing prose \n provides an escape line below.

                // 1. Delete the fence line text.
                textStorage.replaceCharacters(
                    in: fenceLineRange,
                    with: NSAttributedString(string: "", attributes: proseAttrs)
                )
                let insertPos = lineStart
                // 2. Insert anchor \n with code attr.
                textStorage.insert(
                    NSAttributedString(string: "\n", attributes: codeAttrs),
                    at: insertPos
                )
                // 3. Ensure a trailing prose \n exists below.
                let post = textView.string as NSString
                let afterAnchor = insertPos + 1
                let needsTrailingNL: Bool = {
                    if afterAnchor >= post.length { return true }
                    return post.character(at: afterAnchor) != 0x0A
                }()
                if needsTrailingNL {
                    textStorage.insert(
                        NSAttributedString(string: "\n", attributes: proseAttrs),
                        at: afterAnchor
                    )
                }
                // 4. Cursor BEFORE the anchor \n so typed text goes
                //    into the block (anchor \n gets pushed right).
                textView.setSelectedRange(NSRange(location: insertPos, length: 0))
                textView.typingAttributes = codeAttrs
            }

            // Post-transition sync. Deliberately skips
            // updateTypingAttributesForCursor (see isProgrammaticMutation
            // comment above) so our explicit typingAttributes stick.
            isProgrammaticMutation = false
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            textView.needsDisplay = true
            applyCodeBlockStyling(textView: textView)
            syncCodeBlocksFromTextStorage(textView: textView)
            applySlashCommandHighlighting(textView: textView)
            parent.composerState.text = textView.string
            return true
        }

        /// Walk the textStorage's attribute runs and rebuild
        /// `ComposerState.codeBlocks` so serialization sees the current
        /// shape of the document.
        func syncCodeBlocksFromTextStorage(textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            var spans: [ComposerState.CodeBlockSpan] = []
            let full = NSRange(location: 0, length: textStorage.length)
            textStorage.enumerateAttribute(.cmuxCodeBlock, in: full) { value, range, _ in
                guard let language = value as? String else { return }
                spans.append(ComposerState.CodeBlockSpan(range: range, language: language))
            }
            if parent.composerState.codeBlocks != spans {
                parent.composerState.codeBlocks = spans
            }
        }

        /// Apply syntax highlighting and clear stale per-char backgrounds
        /// on code-block ranges. The full-width block background is drawn
        /// in ComposerNSTextView.draw(_:) via NSLayoutManager rects, not
        /// via per-character `.backgroundColor` attributes.
        func applyCodeBlockStyling(textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: textStorage.length)
            guard full.length > 0 else { return }
            textStorage.removeAttribute(.backgroundColor, range: full)
            // No paragraph spacing between code lines — text stays
            // tight within the block. The visual gap between the block
            // and prose comes from CodeBlockLayoutManager's yPad on the
            // drawn rect (outside the text, not inside the line layout).

            // Apply syntax highlighting to code block runs.
            textStorage.enumerateAttribute(.cmuxCodeBlock, in: full) { value, range, _ in
                guard value != nil else { return }
                Self.applySyntaxHighlighting(textStorage: textStorage, range: range)
            }
        }

        // MARK: - Syntax highlighting (lightweight, regex-based)

        /// Common keyword patterns. We keep a small set that covers
        /// Python / JS / TS / Swift / Go / Rust / Shell basics. This is
        /// purely cosmetic — no parse tree, no language detection.
        private static let syntaxRules: [(NSRegularExpression, NSColor)] = {
            let keyword = NSColor(
                srgbRed: 198 / 255.0, green: 120 / 255.0, blue: 221 / 255.0, alpha: 1
            ) // purple
            let string = NSColor(
                srgbRed: 152 / 255.0, green: 195 / 255.0, blue: 121 / 255.0, alpha: 1
            ) // green
            let number = NSColor(
                srgbRed: 209 / 255.0, green: 154 / 255.0, blue: 102 / 255.0, alpha: 1
            ) // orange
            let comment = NSColor(
                srgbRed: 92 / 255.0, green: 99 / 255.0, blue: 112 / 255.0, alpha: 1
            ) // dim gray
            let builtin = NSColor(
                srgbRed: 97 / 255.0, green: 175 / 255.0, blue: 239 / 255.0, alpha: 1
            ) // blue
            return [
                // Line comments (# // --)
                (try! NSRegularExpression(pattern: #"(#|//).*$"#, options: .anchorsMatchLines), comment),
                // Strings (double-quoted and single-quoted, non-greedy)
                (try! NSRegularExpression(pattern: #"\"[^\"\\]*(?:\\.[^\"\\]*)*\""#), string),
                (try! NSRegularExpression(pattern: #"'[^'\\]*(?:\\.[^'\\]*)*'"#), string),
                // Numbers (integers, floats, hex)
                (try! NSRegularExpression(pattern: #"\b(?:0x[\da-fA-F]+|\d+\.?\d*(?:e[+-]?\d+)?)\b"#), number),
                // Keywords
                (try! NSRegularExpression(
                    pattern: #"\b(?:import|from|def|class|func|fn|let|var|const|val|if|else|elif|for|while|return|yield|async|await|try|catch|except|finally|throw|switch|case|break|continue|do|in|of|is|as|not|and|or|with|lambda|struct|enum|impl|trait|interface|type|export|default|package|pub|mut|self|super|nil|null|None|true|false|True|False|undefined|void)\b"#
                ), keyword),
                // Built-in functions / types
                (try! NSRegularExpression(
                    pattern: #"\b(?:print|println|len|range|map|filter|str|int|float|bool|list|dict|set|tuple|type|isinstance|hasattr|getattr|open|close|read|write|append|extend|pop|push|sort|sorted|zip|enumerate|format|join|split|strip|replace|String|Int|Double|Array|Dict|Optional|Result|Error)\b"#
                ), builtin),
            ]
        }()

        /// Apply foreground color rules to a single code-block range.
        /// Resets to a light code text color first, then overlays pattern
        /// matches. Called inside a programmatic-mutation guard.
        private static func applySyntaxHighlighting(
            textStorage: NSTextStorage,
            range: NSRange
        ) {
            // Base code text color (light against the dark block bg).
            let codeBase = NSColor(white: 0.88, alpha: 1)
            textStorage.addAttribute(.foregroundColor, value: codeBase, range: range)

            let text = textStorage.string as NSString
            for (regex, color) in syntaxRules {
                regex.enumerateMatches(
                    in: text as String,
                    options: [],
                    range: range
                ) { match, _, _ in
                    guard let matchRange = match?.range else { return }
                    textStorage.addAttribute(.foregroundColor, value: color, range: matchRange)
                }
            }
        }

        /// Match NSTextView's typingAttributes to whatever run the cursor
        /// is sitting in. Without this, new characters typed just past
        /// the right edge of a code block would carry the block's
        /// attributes back in (and vice versa).
        ///
        /// We inspect both the character *before* the cursor and the
        /// character *at* the cursor: at a boundary (e.g. user clicked
        /// just before the first char of a block), one side is prose
        /// and the other is code. Treating either match as "in block"
        /// keeps typing consistent with the visual position.
        func updateTypingAttributesForCursor(textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            let cursor = textView.selectedRange().location
            var attrs = textView.typingAttributes
            var matchedLanguage: String? = nil
            for probe in [cursor - 1, cursor] {
                guard probe >= 0, probe < textStorage.length else { continue }
                if let language = textStorage.attribute(
                    .cmuxCodeBlock, at: probe, effectiveRange: nil
                ) as? String {
                    matchedLanguage = language
                    break
                }
            }
            if let language = matchedLanguage {
                attrs[.cmuxCodeBlock] = language
            } else {
                attrs.removeValue(forKey: .cmuxCodeBlock)
            }
            // Keep a consistent monospaced font regardless of region.
            attrs[.font] = NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize, weight: .regular
            )
            textView.typingAttributes = attrs
        }

        // MARK: - Code block navigation actions

        /// Insert a prose \n above the code block the cursor is in and
        /// move the cursor to the new blank prose line.
        private func insertProseLineAboveBlock(textView: NSTextView) {
            guard let textStorage = textView.textStorage,
                  let block = codeBlockContainingCursor(textView: textView)
            else { return }
            let monoFont = NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize, weight: .regular
            )
            // Insert via textStorage with an explicit NSAttributedString
            // so the \n is guaranteed prose (no .cmuxCodeBlock) regardless
            // of isRichText or typingAttributes.
            let proseNL = NSAttributedString(
                string: "\n",
                attributes: [.font: monoFont]
            )
            isProgrammaticMutation = true
            textStorage.insert(proseNL, at: block.range.location)
            isProgrammaticMutation = false
            // Cursor on the new prose line.
            textView.setSelectedRange(NSRange(location: block.range.location, length: 0))
            var attrs = textView.typingAttributes
            attrs.removeValue(forKey: .cmuxCodeBlock)
            textView.typingAttributes = attrs
            parent.composerState.text = textView.string
        }

        /// Insert a prose \n after the code block and move cursor there.
        /// Symmetric with insertProseLineAboveBlock (Up at block start).
        private func insertProseLineBelowBlock(textView: NSTextView, block: NSRange) {
            guard let textStorage = textView.textStorage else { return }
            let monoFont = NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize, weight: .regular
            )
            let proseNL = NSAttributedString(
                string: "\n",
                attributes: [.font: monoFont]
            )
            let insertLoc = NSMaxRange(block)
            isProgrammaticMutation = true
            textStorage.insert(proseNL, at: insertLoc)
            isProgrammaticMutation = false
            // Cursor AFTER the new prose \n.
            textView.setSelectedRange(NSRange(location: insertLoc + 1, length: 0))
            var attrs = textView.typingAttributes
            attrs.removeValue(forKey: .cmuxCodeBlock)
            textView.typingAttributes = attrs
            parent.composerState.text = textView.string
        }

        /// Remove code-block status from all chars in the block
        /// containing the cursor, effectively cancelling it. Removes the
        /// trailing anchor \n. Content (if any) stays as plain prose.
        private func cancelCodeBlock(textView: NSTextView) {
            guard let textStorage = textView.textStorage,
                  let block = codeBlockContainingCursor(textView: textView)
            else { return }
            let ns = textView.string as NSString
            var deleteEnd = NSMaxRange(block.range)
            if deleteEnd < ns.length, ns.character(at: deleteEnd) == 0x0A {
                deleteEnd += 1
            }
            let deleteRange = NSRange(
                location: block.range.location,
                length: deleteEnd - block.range.location
            )
            isProgrammaticMutation = true
            textStorage.replaceCharacters(in: deleteRange, with: "")
            isProgrammaticMutation = false
            let cursorPos = min(block.range.location, (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
            var attrs = textView.typingAttributes
            attrs.removeValue(forKey: .cmuxCodeBlock)
            textView.typingAttributes = attrs
            parent.composerState.text = textView.string
        }

        // MARK: - Code block navigation helpers

        /// Returns the code-block span (NSRange + language) that the
        /// cursor sits inside, or nil when the cursor is in prose.
        private func codeBlockContainingCursor(textView: NSTextView) -> (range: NSRange, language: String)? {
            guard let textStorage = textView.textStorage else { return nil }
            let cursor = textView.selectedRange().location
            // Probe both cursor-1 and cursor (same dual-probe logic as
            // updateTypingAttributesForCursor).
            for probe in [cursor - 1, cursor] {
                guard probe >= 0, probe < textStorage.length else { continue }
                var effectiveRange = NSRange()
                if let lang = textStorage.attribute(
                    .cmuxCodeBlock, at: probe, effectiveRange: &effectiveRange
                ) as? String {
                    return (effectiveRange, lang)
                }
            }
            return nil
        }

        /// Whether cursor is at the very start of its containing code
        /// block. Used for Up (insert prose above) and Backspace (cancel).
        private func isCursorAtStartOfCodeBlock(textView: NSTextView) -> Bool {
            guard let textStorage = textView.textStorage else { return false }
            let cursor = textView.selectedRange().location
            // The cursor is "at start" if the char AT cursor has
            // .cmuxCodeBlock but the char at cursor-1 does NOT (or
            // cursor == 0).
            guard cursor < textStorage.length else { return false }
            guard textStorage.attribute(.cmuxCodeBlock, at: cursor, effectiveRange: nil) != nil
            else { return false }
            if cursor == 0 { return true }
            return textStorage.attribute(.cmuxCodeBlock, at: cursor - 1, effectiveRange: nil) == nil
        }

        /// Whether the cursor is on the last content line of its code
        /// block. Determined by searching FORWARD from the cursor for a
        /// `\n` inside the block. If none is found, or the only `\n`
        /// after the cursor is the trailing anchor (the very last char
        /// in the block), the cursor is on the last line.
        private func isCursorOnLastContentLineOfBlock(
            textView: NSTextView,
            block: NSRange
        ) -> Bool {
            let cursor = textView.selectedRange().location
            guard cursor >= block.location, cursor <= NSMaxRange(block) else { return false }
            let ns = textView.string as NSString
            let blockEnd = NSMaxRange(block)
            // Search for a \n from cursor to block end.
            let remaining = blockEnd - cursor
            guard remaining > 0 else { return true } // cursor at/past block end
            let afterCursor = NSRange(location: cursor, length: remaining)
            let nextNL = ns.rangeOfCharacter(from: .newlines, range: afterCursor)
            if nextNL.location == NSNotFound {
                return true // no \n after cursor → last line
            }
            // If the only \n is the very last char of the block (the
            // anchor \n inserted on entry), the cursor is still on the
            // last content line.
            return nextNL.location == blockEnd - 1
        }

        // MARK: - Slash completion logic

        func updateSlashCompletion(text: String) {
            guard text.hasPrefix("/") else {
                parent.composerState.showCompletion = false
                return
            }
            let afterSlash = text.dropFirst()
            let commandToken: String
            if let spaceIndex = afterSlash.firstIndex(of: " ") {
                commandToken = String(afterSlash[afterSlash.startIndex..<spaceIndex])
                parent.composerState.showCompletion = false
                return
            } else {
                commandToken = String(afterSlash)
            }
            parent.composerState.completionFilter = commandToken
            parent.composerState.completionSelectedIndex = 0
            parent.composerState.showCompletion = true
        }

        // MARK: - Text highlighting

        func applySlashCommandHighlighting(textView: NSTextView) {
            guard !textView.hasMarkedText() else { return }
            guard let textStorage = textView.textStorage else { return }

            let text = textView.string
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            guard fullRange.length > 0 else { return }

            isProgrammaticMutation = true
            defer { isProgrammaticMutation = false }

            textStorage.addAttribute(
                .foregroundColor,
                value: NSColor.labelColor,
                range: fullRange
            )

            // Highlight [IMAGE #N] markers in teal
            if let regex = try? NSRegularExpression(pattern: #"\[IMAGE #\d+\]"#) {
                let matches = regex.matches(in: text, range: fullRange)
                for match in matches {
                    textStorage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: match.range)
                }
            }

            // Highlight slash commands
            guard text.hasPrefix("/") else { return }
            let afterSlash = text.dropFirst()
            let commandEnd = afterSlash.firstIndex(of: " ") ?? afterSlash.endIndex
            let commandName = String(afterSlash[afterSlash.startIndex..<commandEnd])
            guard !commandName.isEmpty else { return }

            if SlashCommandRegistry.shared.isKnownCommand(commandName) {
                let commandRange = NSRange(location: 0, length: 1 + commandName.count)
                textStorage.addAttribute(
                    .foregroundColor,
                    value: NSColor.systemBlue,
                    range: commandRange
                )
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposerScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // Manually build a TextKit 1 stack so our custom
        // NSLayoutManager.drawBackground is called (macOS 12+ defaults
        // to TextKit 2 where NSLayoutManager overrides are ignored).
        let textStorage = NSTextStorage()
        let layoutManager = CodeBlockLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = ComposerNSTextView(frame: .zero, textContainer: textContainer)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.string = composerState.text

        let placeholder = String(
            localized: "composer.placeholder",
            defaultValue: "Compose your prompt\u{2026} (\u{2318}Enter to send, Esc to dismiss)"
        )
        textView.placeholderText = placeholder
        textView.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onBecomeFirstResponder()
        }
        textView.onImagePasted = { [weak textView] in
            guard let textView else { return }
            let state = context.coordinator.parent.composerState
            if let imageURL = state.saveImageFromPasteboard() {
                let marker = state.addImage(url: imageURL)
                // Insert thumbnail attachment into text view
                context.coordinator.insertImageAttachment(
                    in: textView, imageURL: imageURL, marker: marker
                )
            }
        }
        textView.setAccessibilityLabel(placeholder)

        textView.registerForDraggedTypes([.fileURL, .png, .tiff])

        scrollView.documentView = textView
        scrollView.onCmdEnter = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSendAndSubmit()
        }

        // Arm the viewDidMoveToWindow tripwire so the textView grabs first
        // responder the moment the SwiftUI tree finishes mounting it in a
        // window. Belt-and-braces with the makeFirstResponder calls in
        // updateNSView; necessary because SwiftUI's first updateNSView can
        // fire before nsView.window is set, in which case those calls bail.
        textView.pendingAutoFocusOnWindowAttach = true

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? ComposerNSTextView else { return }

        if textView.string != composerState.text, !textView.hasMarkedText() {
            context.coordinator.isProgrammaticMutation = true
            textView.string = composerState.text
            context.coordinator.applySlashCommandHighlighting(textView: textView)
            context.coordinator.isProgrammaticMutation = false
        }

        // Apply bash-mode theme to the NSTextView when the state flips.
        if textView.isBashMode != composerState.bashMode {
            textView.isBashMode = composerState.bashMode
            textView.applyBashModeAppearance(composerState.bashMode)
        }

        // Re-focus whenever a new ComposerState appears (Composer reopened).
        let currentStateID = ObjectIdentifier(composerState)
        if context.coordinator.lastFocusedStateID != currentStateID,
           textView.superview != nil {
            context.coordinator.lastFocusedStateID = currentStateID
            // Always arm the viewDidMoveToWindow tripwire — it is the only
            // signal that fires deterministically once SwiftUI has mounted
            // the text view inside a window. Without this we would lose
            // focus when SwiftUI's first updateNSView happens before the
            // scroll view is in a window (the if-let below would skip the
            // immediate claim and no further updateNSView would fire).
            textView.pendingAutoFocusOnWindowAttach = true
            if let window = nsView.window {
                // Claim focus with multiple attempts to handle timing:
                // 1. Sync: immediate claim
                // 2. Async: next run loop (composerIsActive flag should be set)
                // 3. Delayed: after terminal focus reclamation has settled
                window.makeFirstResponder(textView)
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, let window = textView.window else { return }
                    window.makeFirstResponder(textView)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak textView] in
                    guard let textView, let window = textView.window else { return }
                    window.makeFirstResponder(textView)
                }
            }
            // If window is nil, viewDidMoveToWindow will fire the claim once
            // the SwiftUI hierarchy finishes mounting.
        }
    }
}

// MARK: - Inline pill image attachment cell (swatch + label, hover for full preview)

private final class ComposerImageAttachmentCell: NSTextAttachmentCell {
    let marker: String
    let fullImageURL: URL
    private let swatch: NSImage
    private let pillHeight: CGFloat = 18
    private let swatchSize: CGFloat = 14
    private let hPadding: CGFloat = 4
    private let cornerRadius: CGFloat = 4

    init(swatch: NSImage, marker: String, fullImageURL: URL) {
        self.swatch = swatch
        self.marker = marker
        self.fullImageURL = fullImageURL
        super.init(imageCell: swatch)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override func cellSize() -> NSSize {
        let labelWidth = ceil((marker as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]
        ).width)
        let w = hPadding + swatchSize + 4 + labelWidth + hPadding + 2 // +2 safety
        return NSSize(width: w, height: pillHeight)
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -3)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let rect = cellFrame

        // Pill background
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.secondarySystemFill.setFill()
        bgPath.fill()

        // Swatch (left side, vertically centered)
        let swatchY = rect.origin.y + (rect.height - swatchSize) / 2
        let swatchRect = NSRect(
            x: rect.origin.x + hPadding,
            y: swatchY,
            width: swatchSize,
            height: swatchSize
        )
        let swatchClip = NSBezierPath(roundedRect: swatchRect, xRadius: 2, yRadius: 2)
        NSGraphicsContext.current?.saveGraphicsState()
        swatchClip.addClip()
        swatch.draw(in: swatchRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.current?.restoreGraphicsState()

        // Label (right of swatch)
        let labelX = rect.origin.x + hPadding + swatchSize + 4
        let labelRect = NSRect(
            x: labelX,
            y: rect.origin.y + 2,
            width: rect.width - (labelX - rect.origin.x) - hPadding,
            height: pillHeight - 4
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        (marker as NSString).draw(in: labelRect, withAttributes: attrs)
    }

    override func wantsToTrackMouse() -> Bool { true }
}

// MARK: - NSTextView subclass with placeholder text, image paste, and drag-drop

private final class ComposerNSTextView: NSTextView {
    var placeholderText: String = ""
    var onBecomeFirstResponder: (() -> Void)?
    var onImagePasted: (() -> Void)?
    /// Set by `ComposerTextViewRepresentable.makeNSView` (and re-armed by
    /// updateNSView when a fresh ComposerState appears). Causes the next
    /// `viewDidMoveToWindow` callback to claim firstResponder, which is the
    /// only reliable signal that the SwiftUI tree has finished mounting this
    /// text view inside its window.
    ///
    /// Why we need this: SwiftUI's first `updateNSView` call can fire while
    /// `nsView.window` is still nil — the auto-focus path there bails, and no
    /// further `updateNSView` calls fire because nothing on `composerState`
    /// changes. Without this tripwire, the composer never grabs first
    /// responder and the user's typing/paste falls through to the terminal.
    var pendingAutoFocusOnWindowAttach: Bool = false
    /// Mirrors `ComposerState.bashMode` so updateNSView can detect the
    /// transition and apply/revert the dark terminal theme.
    var isBashMode: Bool = false
    private var imagePopover: NSPopover?
    private var hoverTrackingArea: NSTrackingArea?

    // Bash-mode breathing block cursor state.
    private var bashCursorTimer: Timer?
    private var bashBreathPhase: Double = 0

    deinit {
        // Timer captures weak self but be explicit about teardown.
        bashCursorTimer?.invalidate()
    }

    /// Switch the NSTextView's native theme to/from the bash-mode look.
    /// Called from updateNSView on every bashMode transition.
    func applyBashModeAppearance(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            if on {
                self.appearance = NSAppearance(named: .darkAqua)
                self.drawsBackground = true
                // #0D1117 — matches the SwiftUI gradient's top color so the
                // NSTextView visually sits inside the card rather than
                // floating above it.
                self.backgroundColor = NSColor(
                    srgbRed: 0x0D / 255.0, green: 0x11 / 255.0, blue: 0x17 / 255.0, alpha: 1
                )
                self.textColor = NSColor(white: 0.92, alpha: 1)
                self.insertionPointColor = NSColor(
                    srgbRed: 0x2E / 255.0, green: 0xE5 / 255.0, blue: 0x9D / 255.0, alpha: 1
                )
                // Carve a first-line left margin so the ❯ prompt we draw in
                // draw(_:) has room without overlapping user text. Using
                // exclusionPaths (rather than textContainerInset or
                // lineFragmentPadding, both of which are symmetric) lets us
                // affect only the first line's left edge.
                self.textContainer?.exclusionPaths = [Self.bashPromptExclusionPath(
                    font: self.font ?? NSFont.monospacedSystemFont(
                        ofSize: NSFont.systemFontSize, weight: .regular
                    )
                )]
            } else {
                self.appearance = nil
                self.drawsBackground = false
                self.backgroundColor = .clear
                self.textColor = .labelColor
                // Restore default — AppKit picks the system accent color.
                self.insertionPointColor = .textInsertionPointColor
                self.textContainer?.exclusionPaths = []
            }
            self.needsDisplay = true
        }
        // Start/stop the breathing-cursor driver.
        if on {
            startBashCursorTimer()
        } else {
            stopBashCursorTimer()
        }
    }

    // MARK: - Bash-mode block cursor with breathing animation

    /// Override the insertion point to render as a block in bash mode, with
    /// an opacity driven by our sin-wave breath phase. IME marked text
    /// defers to the system drawing so composition cursor behaves correctly.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard isBashMode, !hasMarkedText() else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        let charWidth: CGFloat = {
            guard let font = self.font else { return 8 }
            let advance = font.maximumAdvancement.width
            return advance > 0 ? advance : font.pointSize * 0.55
        }()
        let block = NSRect(
            x: rect.origin.x,
            y: rect.origin.y + 1,
            width: max(charWidth, 2),
            height: max(rect.height - 2, 2)
        )
        // 0.35 → 1.0 → 0.35 breathing curve; `turnedOn` from the system
        // blink timer is intentionally ignored — we drive the full effect
        // from our own timer.
        let breath = 0.35 + 0.65 * (sin(bashBreathPhase) * 0.5 + 0.5)
        color.withAlphaComponent(CGFloat(breath)).setFill()
        NSBezierPath(roundedRect: block, xRadius: 1, yRadius: 1).fill()
    }

    private func startBashCursorTimer() {
        stopBashCursorTimer()
        // ~30 fps is smooth enough for a slow breath without taxing the GPU.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Tuned so a full cycle takes ~1.6s.
            self.bashBreathPhase += 0.13
            // Invalidating the whole bounds is fine: this is a small text
            // view and the compositor only redraws dirty tiles.
            self.needsDisplay = true
        }
        // Schedule on .common so it continues during tracking loops
        // (scrolling, menu interaction, etc.).
        RunLoop.main.add(timer, forMode: .common)
        bashCursorTimer = timer
    }

    private func stopBashCursorTimer() {
        bashCursorTimer?.invalidate()
        bashCursorTimer = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard pendingAutoFocusOnWindowAttach, let window = self.window else { return }
        pendingAutoFocusOnWindowAttach = false
        window.makeFirstResponder(self)
    }

    // Declare that this text view can accept image pasteboard types.
    // Without this, Paste is grayed out when the clipboard has only image data
    // (isRichText=false means the default only accepts .string).
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        if !types.contains(.tiff) { types.append(.tiff) }
        if !types.contains(.png) { types.append(.png) }
        return types
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onBecomeFirstResponder?() }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        // Code-block backgrounds are drawn by CodeBlockLayoutManager
        // .drawBackground(forGlyphRange:at:) — called by TextKit during
        // its own rendering pass, so no custom draw needed here.
        super.draw(dirtyRect)

        // Bash-mode ❯ prompt, drawn in the same coordinate system as the
        // NSTextView's text so font size and baseline match exactly.
        if isBashMode {
            drawBashPrompt()
        }

        guard string.isEmpty, !placeholderText.isEmpty else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let inset = textContainerInset
        // When in bash mode we carved a left exclusion band for the prompt;
        // nudge the placeholder past it so "Compose your prompt…" doesn't
        // overdraw the ❯.
        let leftNudge: CGFloat = isBashMode
            ? Self.bashPromptColumnWidth(font: font
                ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
            : 0
        let origin = NSPoint(
            x: inset.width + (textContainer?.lineFragmentPadding ?? 0) + leftNudge,
            y: inset.height
        )
        NSAttributedString(string: placeholderText, attributes: attrs)
            .draw(at: origin)
    }

    // MARK: - Bash-mode prompt

    /// Width reserved at the start of the first line for the ❯ prompt and a
    /// small gap. Kept as a single source of truth so the exclusion path,
    /// placeholder offset, and actual prompt render all agree.
    fileprivate static func bashPromptColumnWidth(font: NSFont) -> CGFloat {
        let charWidth = font.maximumAdvancement.width > 0
            ? font.maximumAdvancement.width
            : font.pointSize * 0.6
        return charWidth + 6
    }

    /// Exclusion band that pushes the first line of text right far enough to
    /// clear the ❯ prompt. Only the first line is affected; continuation
    /// lines flow back to the normal left edge.
    fileprivate static func bashPromptExclusionPath(font: NSFont) -> NSBezierPath {
        let w = bashPromptColumnWidth(font: font)
        let h = ceil(font.ascender - font.descender + font.leading) + 4
        return NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h))
    }

    private func drawBashPrompt() {
        guard let font = self.font else { return }
        let color = NSColor(
            srgbRed: 0x2E / 255.0, green: 0xE5 / 255.0, blue: 0x9D / 255.0, alpha: 1
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let inset = textContainerInset
        let origin = NSPoint(
            x: inset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: inset.height
        )
        NSAttributedString(string: "\u{276F}", attributes: attrs).draw(at: origin)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    // MARK: - Image paste

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        let hasImage = types.contains(.tiff) || types.contains(.png)
        // Check for image FIRST (fixes screenshot paste: screenshots put a file URL
        // on the clipboard that stringContents() picks up, bypassing image handling).
        if hasImage {
            onImagePasted?()
            return
        }
        super.paste(sender)
    }

    // MARK: - Image drag & drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if pb.types?.contains(.fileURL) == true || pb.types?.contains(.png) == true || pb.types?.contains(.tiff) == true {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let content = TerminalImageTransferPlanner.prepare(pasteboard: pb, mode: .drop)
        switch content {
        case .fileURLs(let urls):
            // For image files, use the image marker system
            let imageTypes = Set(["png", "jpg", "jpeg", "gif", "tiff", "tif", "webp", "bmp"])
            var handled = false
            for url in urls {
                if imageTypes.contains(url.pathExtension.lowercased()) {
                    onImagePasted?()
                    handled = true
                } else {
                    let path = GhosttyPasteboardHelper.escapeForShell(url.path)
                    insertText(path + " ", replacementRange: selectedRange())
                    handled = true
                }
            }
            return handled
        case .insertText(let text):
            insertText(text, replacementRange: selectedRange())
            return true
        case .reject:
            return super.performDragOperation(sender)
        }
    }

    // MARK: - Image hover preview

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)

        guard charIndex < (string as NSString).length else {
            dismissImagePopover()
            super.mouseMoved(with: event)
            return
        }

        // Check if character at index is an attachment (U+FFFC)
        let ch = (string as NSString).character(at: charIndex)
        guard ch == 0xFFFC,
              let textStorage = textStorage,
              let attachment = textStorage.attribute(.attachment, at: charIndex, effectiveRange: nil) as? NSTextAttachment,
              let cell = attachment.attachmentCell as? ComposerImageAttachmentCell else {
            dismissImagePopover()
            super.mouseMoved(with: event)
            return
        }

        // Already showing popover for this attachment
        if imagePopover?.isShown == true { return }

        showImagePopover(for: cell.fullImageURL, at: charIndex)
    }

    private func showImagePopover(for imageURL: URL, at charIndex: Int) {
        guard let image = NSImage(contentsOf: imageURL) else { return }

        let maxPreviewSize: CGFloat = 240
        let aspect = image.size.width / max(image.size.height, 1)
        let previewW: CGFloat
        let previewH: CGFloat
        if aspect > 1 {
            previewW = maxPreviewSize
            previewH = maxPreviewSize / aspect
        } else {
            previewH = maxPreviewSize
            previewW = maxPreviewSize * aspect
        }

        let imageView = NSImageView(frame: NSRect(x: 8, y: 8, width: previewW, height: previewH))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let container = NSView(frame: NSRect(x: 0, y: 0, width: previewW + 16, height: previewH + 16))
        container.addSubview(imageView)

        let vc = NSViewController()
        vc.view = container

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.contentSize = container.frame.size
        popover.behavior = .semitransient
        popover.animates = true

        // Get the rect for the attachment character
        let glyphRange = layoutManager?.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil) ?? NSRange(location: charIndex, length: 1)
        let lineRect = layoutManager?.boundingRect(forGlyphRange: glyphRange, in: textContainer!) ?? .zero
        let attachRect = NSRect(
            x: lineRect.origin.x + textContainerInset.width,
            y: lineRect.origin.y + textContainerInset.height,
            width: max(lineRect.width, 20),
            height: max(lineRect.height, 18)
        )

        imagePopover = popover
        popover.show(relativeTo: attachRect, of: self, preferredEdge: .maxY)
    }

    private func dismissImagePopover() {
        imagePopover?.performClose(nil)
        imagePopover = nil
    }
}

// MARK: - Scroll view that intercepts Cmd+Enter

private final class ComposerScrollView: NSScrollView {
    var onCmdEnter: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+Enter → send and submit (press Enter in CC too)
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 0x24 {
            onCmdEnter?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// Safe array subscript is defined in CompletionPopupView.swift.
