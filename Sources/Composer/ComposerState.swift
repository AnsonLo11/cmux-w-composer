import Foundation
import AppKit

/// Observable state for the composer input overlay.
/// Created when the composer is shown, nilled out when hidden.
/// Draft text is preserved externally so it survives show/hide cycles.
final class ComposerState: ObservableObject {
    @Published var text: String
    /// Whether the slash completion popup is visible.
    @Published var showCompletion: Bool = false
    /// Current filter string for slash completion (without the leading /).
    @Published var completionFilter: String = ""
    /// Currently selected index in the completion list.
    @Published var completionSelectedIndex: Int = 0

    // MARK: - File completion (@-triggered)

    /// Whether the `@`-file completion popup is visible.
    @Published var showFileCompletion: Bool = false
    /// Filter characters after the `@` and before the cursor.
    @Published var fileCompletionFilter: String = ""
    /// Resolved file entries for the current cwd + filter.
    @Published var fileCompletionItems: [FileEntry] = []
    /// Selected row in the file completion popup.
    @Published var fileCompletionSelectedIndex: Int = 0
    /// Range of `@filter` within the text, used to replace on acceptance.
    var fileCompletionTokenRange: NSRange = .init(location: 0, length: 0)

    /// Attached images: marker index → file URL.
    @Published var attachedImages: [Int: URL] = [:]
    /// Next image index (increments per composer session).
    private(set) var nextImageIndex: Int = 1

    /// Current position in history navigation (-1 = not browsing history).
    var historyIndex: Int = -1
    /// Saved current text when user enters history mode.
    var savedCurrentText: String = ""

    // MARK: - Code blocks (```)

    /// A single code-block region within `text`. `range` is over the
    /// display text (which does NOT include the fence characters — those
    /// are consumed when the user triggers entry/exit). `language` is the
    /// identifier the user typed after the opening fence (empty for an
    /// unlabeled block). Used both to paint the gray background in the
    /// NSTextView and to wrap the content in standard markdown ``` fences
    /// on send.
    struct CodeBlockSpan: Equatable {
        var range: NSRange
        var language: String
    }

    /// All code-block spans, left-to-right, non-overlapping. Maintained
    /// by the composer's Coordinator on every text change.
    @Published var codeBlocks: [CodeBlockSpan] = []

    /// Unicode triggers the composer treats as a code-block fence. The
    /// first element (``) is the canonical form emitted during send;
    /// `～～～` (U+FF5E full-width tilde, common on CN/JP keyboards) and
    /// `···` (U+00B7 middle dot, what the pinyin IME emits for the
    /// backtick key) are aliases that normalise to ``` when serialised
    /// for CC.
    static let codeBlockFenceCharacters: [Character] = ["\u{0060}", "\u{FF5E}", "\u{00B7}"]

    /// Parse a line and report whether it's a fence trigger. Returns the
    /// language tag (possibly empty) when matched, or nil when the line
    /// is not a fence.
    ///
    /// A fence line is exactly three consecutive fence characters (all
    /// the same character) optionally followed by a language identifier
    /// made of non-whitespace characters. Mixed fence characters (e.g.
    /// `\`\`~` ) do not match — this avoids false triggers when a user
    /// is quoting real backticks.
    static func parseFenceLine(_ line: String) -> String? {
        let trimmed = line
        guard trimmed.count >= 3 else { return nil }
        let first = trimmed.first!
        guard codeBlockFenceCharacters.contains(first) else { return nil }
        let prefix = trimmed.prefix(3)
        guard prefix.allSatisfy({ $0 == first }) else { return nil }
        let rest = trimmed.dropFirst(3)
        // Language tag must not contain whitespace.
        guard rest.allSatisfy({ !$0.isWhitespace }) else { return nil }
        return String(rest)
    }

    // MARK: - Bash mode

    /// Whether the composer is rendering its bash-mode theme. When true,
    /// sends are prefixed with an English `!` and history navigation reads
    /// from `bashHistory` rather than `sendHistory`.
    @Published var bashMode: Bool = false

    /// True iff the given text is a single character that should toggle
    /// the composer into bash mode. Accepts both English `!` (U+0021) and
    /// full-width Chinese `！` (U+FF01) so IME users can trigger it without
    /// switching layouts.
    static func shouldEnterBashMode(text: String) -> Bool {
        return text == "!" || text == "\u{FF01}"
    }

    /// Resolves the outgoing PTY payload: the sendable text, with an
    /// English `!` prefix when bashMode is active. Always ASCII.
    func payloadForSending() -> String {
        let resolved = resolvedTextForSending()
        return bashMode ? "!" + resolved : resolved
    }

    /// Wraps each code-block span in `codeBlocks` with standard markdown
    /// ``` fences (using the canonical ASCII backtick, regardless of
    /// which fence character the user typed to trigger the block). Prose
    /// outside code blocks is emitted verbatim.
    ///
    /// Called from `resolvedTextForSending` so the rest of the send
    /// pipeline (image attachments, bash `!` prefix) sees the already-
    /// fenced markdown.
    func textWithCodeFencesApplied(to base: String) -> String {
        guard !codeBlocks.isEmpty else { return base }
        let ns = base as NSString
        // Sort by location, defensively, and clip to bounds.
        let spans = codeBlocks
            .filter { NSMaxRange($0.range) <= ns.length && $0.range.length >= 0 }
            .sorted { $0.range.location < $1.range.location }
        var out = ""
        var cursor = 0
        for span in spans {
            if span.range.location > cursor {
                out += ns.substring(with: NSRange(
                    location: cursor,
                    length: span.range.location - cursor
                ))
            }
            let content = ns.substring(with: span.range)
            // Ensure fences live on their own lines: add leading newline
            // if we're not already at a line boundary, and trailing
            // newline before the closing fence if content doesn't end
            // with one.
            let needsLeadingNL = !out.isEmpty && !out.hasSuffix("\n")
            out += (needsLeadingNL ? "\n" : "") + "```" + span.language + "\n"
            out += content
            if !content.hasSuffix("\n") { out += "\n" }
            out += "```\n"
            cursor = NSMaxRange(span.range)
        }
        if cursor < ns.length {
            out += ns.substring(from: cursor)
        }
        return out
    }

    init(text: String = "") {
        self.text = text
    }

    // MARK: - Send history (persists across Composer sessions)

    /// Shared history of sent prompts (most recent last).
    private static var sendHistory: [String] = []
    /// Separate history for bash-mode sends so up/down navigation doesn't
    /// mix chat prompts with shell commands.
    private static var bashHistory: [String] = []
    private static let maxHistoryCount = 50

    /// Record a sent prompt in history.
    static func recordSentText(_ text: String) {
        appendToHistory(&sendHistory, text: text)
    }

    /// Record a bash-mode command in the independent bash history.
    static func recordBashText(_ text: String) {
        appendToHistory(&bashHistory, text: text)
    }

    /// Test hook — clears both histories. `@MainActor` isn't required but
    /// callers typically run on main.
    static func resetAllHistoriesForTesting() {
        sendHistory = []
        bashHistory = []
    }

    private static func appendToHistory(_ history: inout [String], text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if history.last != trimmed {
            history.append(trimmed)
            if history.count > maxHistoryCount {
                history.removeFirst()
            }
        }
    }

    /// Navigate history. Returns the text to show, or nil if at boundary.
    /// Reads from the bash history when `bashMode` is on.
    func historyUp() -> String? {
        let history = bashMode ? Self.bashHistory : Self.sendHistory
        guard !history.isEmpty else { return nil }
        if historyIndex == -1 {
            // Entering history mode: save current text
            savedCurrentText = text
            historyIndex = history.count - 1
        } else if historyIndex > 0 {
            historyIndex -= 1
        } else {
            return nil // already at oldest
        }
        return history[historyIndex]
    }

    func historyDown() -> String? {
        let history = bashMode ? Self.bashHistory : Self.sendHistory
        guard historyIndex >= 0 else { return nil }
        if historyIndex < history.count - 1 {
            historyIndex += 1
            return history[historyIndex]
        } else {
            // Back to current unsent text
            historyIndex = -1
            return savedCurrentText
        }
    }

    func resetHistoryNavigation() {
        historyIndex = -1
        savedCurrentText = ""
    }

    /// Add an image, returns the marker string to insert (e.g. "[IMAGE #1]").
    func addImage(url: URL) -> String {
        let index = nextImageIndex
        nextImageIndex += 1
        attachedImages[index] = url
        imageInsertionOrder.append(index)
        return "[IMAGE #\(index)]"
    }

    /// Resolve the display text to sendable text by replacing image references with file paths.
    /// Handles both [IMAGE #N] text markers and U+FFFC attachment characters.
    func resolvedTextForSending() -> String {
        var result = textWithCodeFencesApplied(to: text)
        // Replace [IMAGE #N] text markers (fallback path)
        for (index, url) in attachedImages {
            let marker = "[IMAGE #\(index)]"
            let path = GhosttyPasteboardHelper.escapeForShell(url.path)
            result = result.replacingOccurrences(of: marker, with: path)
        }
        // Replace U+FFFC attachment characters (thumbnail path).
        // Each U+FFFC in left-to-right order maps to the next image in insertion order.
        // Use sorted keys as fallback if imageInsertionOrder is incomplete.
        let attachmentChar: Character = "\u{FFFC}"
        let orderedIndices = imageInsertionOrder.isEmpty
            ? attachedImages.keys.sorted()
            : imageInsertionOrder
        var indexIterator = orderedIndices.makeIterator()
        var resolved = ""
        for ch in result {
            if ch == attachmentChar {
                if let imgIndex = indexIterator.next(),
                   let url = attachedImages[imgIndex] {
                    resolved += GhosttyPasteboardHelper.escapeForShell(url.path)
                }
                // If no more images, drop the orphan U+FFFC
            } else {
                resolved.append(ch)
            }
        }
        return resolved
    }

    /// Tracks the order images were inserted (for resolving U+FFFC attachment chars in order).
    private(set) var imageInsertionOrder: [Int] = []

    // MARK: - Image saving

    private static let imageDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/image-cache/cmux-composer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Save clipboard image data to the composer image directory.
    /// Returns the file URL if successful.
    func saveImageFromPasteboard(_ pasteboard: NSPasteboard = .general) -> URL? {
        // Try saving via the existing helper (handles PNG/TIFF/RTFD/NSImage)
        if let imageURL = GhosttyPasteboardHelper.saveImageFileURLIfNeeded(
            from: pasteboard, assumeNoText: true
        ) {
            // Move from temp to our image directory with sequential naming
            let destURL = Self.imageDir.appendingPathComponent("image_\(nextImageIndex).png")
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: imageURL, to: destURL)
                return destURL
            } catch {
                // Fall back to the temp location
                return imageURL
            }
        }

        // Fallback: try to get image data directly from pasteboard
        if let image = NSImage(pasteboard: pasteboard),
           let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            let destURL = Self.imageDir.appendingPathComponent("image_\(nextImageIndex).png")
            do {
                try pngData.write(to: destURL)
                return destURL
            } catch {
                return nil
            }
        }

        return nil
    }
}
