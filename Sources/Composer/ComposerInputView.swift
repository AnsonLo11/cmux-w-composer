import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerInputView: View {
    @ObservedObject var composerState: ComposerState
    let onSend: (String) -> Void
    let onDismiss: () -> Void
    let onTextViewBecameFirstResponder: () -> Void

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
        VStack(spacing: 0) {
            // Slash completion popup (above the composer card)
            if composerState.showCompletion {
                let filtered = SlashCommandRegistry.shared.matching(composerState.completionFilter)
                if !filtered.isEmpty {
                    SlashCompletionView(
                        commands: filtered,
                        selectedIndex: $composerState.completionSelectedIndex,
                        onSelect: { command in
                            insertCompletedCommand(command)
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }
            // Composer card
            VStack(spacing: 0) {
                // Drag handle for resizing
                composerDragHandle

                // Text input area (full width)
                ComposerTextViewRepresentable(
                    composerState: composerState,
                    onSend: {
                        let content = composerState.text
                        guard !content.isEmpty else { return }
                        onSend(content)
                    },
                    onDismiss: onDismiss,
                    onBecomeFirstResponder: onTextViewBecameFirstResponder,
                    onInsertCommand: { command in
                        insertCompletedCommand(command)
                    }
                )
                .frame(height: effectiveHeight)

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

                    // Send button
                    Button(action: {
                        let content = composerState.text
                        guard !content.isEmpty else { return }
                        onSend(content)
                    }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(
                                composerState.text.isEmpty
                                    ? Color.primary.opacity(0.15)
                                    : Color.primary.opacity(0.5)
                            )
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
            .background(.background.opacity(0.97))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .onAppear {
            SlashCommandRegistry.shared.reloadIfNeeded()
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
        let paths = panel.urls
            .map { GhosttyPasteboardHelper.escapeForShell($0.path) }
            .joined(separator: " ")
        guard !paths.isEmpty else { return }
        if composerState.text.isEmpty {
            composerState.text = paths + " "
        } else {
            composerState.text += (composerState.text.hasSuffix(" ") ? "" : " ") + paths + " "
        }
    }
}

// MARK: - NSTextView wrapper

/// An NSTextView with full IME, multi-line editing, and mouse cursor support.
/// Cmd+Enter sends text; Escape dismisses; slash commands trigger completion.
private struct ComposerTextViewRepresentable: NSViewRepresentable {
    @ObservedObject var composerState: ComposerState
    let onSend: () -> Void
    let onDismiss: () -> Void
    let onBecomeFirstResponder: () -> Void
    let onInsertCommand: (SlashCommand) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextViewRepresentable
        var isProgrammaticMutation = false
        var hasAppliedInitialFocus = false

        init(parent: ComposerTextViewRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticMutation else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.composerState.text = textView.string
            updateSlashCompletion(text: textView.string)
            applySlashCommandHighlighting(textView: textView)
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
                parent.onDismiss()
                return true
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
            // Plain Enter inserts newline (default behavior)
            // Cmd+Enter is handled via performKeyEquivalent on the scroll view subclass
            return false
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

        let textView = ComposerNSTextView()
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
        textView.onImagePasted = { path in
            context.coordinator.parent.composerState.text += (context.coordinator.parent.composerState.text.isEmpty ? "" : " ") + path + " "
        }
        textView.setAccessibilityLabel(placeholder)

        textView.registerForDraggedTypes([.fileURL, .png, .tiff])

        scrollView.documentView = textView
        scrollView.onCmdEnter = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSend()
        }

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

        if !context.coordinator.hasAppliedInitialFocus,
           let window = nsView.window,
           textView.superview != nil {
            context.coordinator.hasAppliedInitialFocus = true
            DispatchQueue.main.async {
                window.makeFirstResponder(textView)
            }
        }
    }
}

// MARK: - NSTextView subclass with placeholder text, image paste, and drag-drop

private final class ComposerNSTextView: NSTextView {
    var placeholderText: String = ""
    var onBecomeFirstResponder: (() -> Void)?
    var onImagePasted: ((String) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onBecomeFirstResponder?() }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholderText.isEmpty else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let inset = textContainerInset
        let origin = NSPoint(
            x: inset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: inset.height
        )
        NSAttributedString(string: placeholderText, attributes: attrs)
            .draw(at: origin)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    // MARK: - Image paste

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if GhosttyPasteboardHelper.stringContents(from: pb) != nil {
            super.paste(sender)
            return
        }
        if let imageURL = GhosttyPasteboardHelper.saveImageFileURLIfNeeded(
            from: pb, assumeNoText: true
        ) {
            let path = GhosttyPasteboardHelper.escapeForShell(imageURL.path)
            onImagePasted?(path)
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
            let paths = urls
                .map { GhosttyPasteboardHelper.escapeForShell($0.path) }
                .joined(separator: " ")
            if !paths.isEmpty {
                insertText(paths + " ", replacementRange: selectedRange())
                return true
            }
            return false
        case .insertText(let text):
            insertText(text, replacementRange: selectedRange())
            return true
        case .reject:
            return super.performDragOperation(sender)
        }
    }
}

// MARK: - Scroll view that intercepts Cmd+Enter

private final class ComposerScrollView: NSScrollView {
    var onCmdEnter: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 0x24 {
            onCmdEnter?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
