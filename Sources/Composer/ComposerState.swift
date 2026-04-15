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

    init(text: String = "") {
        self.text = text
    }

    // MARK: - Send history (persists across Composer sessions)

    /// Shared history of sent prompts (most recent last).
    private static var sendHistory: [String] = []
    private static let maxHistoryCount = 50

    /// Record a sent prompt in history.
    static func recordSentText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Avoid consecutive duplicates
        if sendHistory.last != trimmed {
            sendHistory.append(trimmed)
            if sendHistory.count > maxHistoryCount {
                sendHistory.removeFirst()
            }
        }
    }

    /// Navigate history. Returns the text to show, or nil if at boundary.
    func historyUp() -> String? {
        let history = Self.sendHistory
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
        let history = Self.sendHistory
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
        var result = text
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
