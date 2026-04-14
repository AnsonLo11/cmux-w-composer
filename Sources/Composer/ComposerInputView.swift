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
                    onSendAndSubmit: {
                        let content = composerState.text
                        guard !content.isEmpty else { return }
                        onSendAndSubmit(content)
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

                    // Send button (same as Enter: send to terminal input)
                    Button(action: {
                        let content = composerState.text
                        guard !content.isEmpty else { return }
                        onSendAndSubmit(content)
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
        for url in panel.urls {
            let marker = composerState.addImage(url: url)
            let prefix = composerState.text.isEmpty || composerState.text.hasSuffix(" ") ? "" : " "
            composerState.text += prefix + marker + " "
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
            // Reset history navigation when user types (not when browsing history)
            parent.composerState.resetHistoryNavigation()
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
            // Shift+Enter → insert newline (default behavior)
            // Plain Enter → send text to terminal
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                    return false // let NSTextView insert newline
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
            // Claim focus with multiple attempts to handle timing:
            // 1. Sync: immediate claim (might be too early for window hierarchy)
            // 2. Async: next run loop (composerIsActive flag should be set by now)
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
    private var imagePopover: NSPopover?
    private var hoverTrackingArea: NSTrackingArea?

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

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
