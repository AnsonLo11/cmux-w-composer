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

    /// Attached images: marker index → file URL.
    @Published var attachedImages: [Int: URL] = [:]
    /// Next image index (increments per composer session).
    private(set) var nextImageIndex: Int = 1

    init(text: String = "") {
        self.text = text
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
        // Attachments appear in text order; imageInsertionOrder tracks which image each one is.
        let attachmentChar = "\u{FFFC}"
        for index in imageInsertionOrder {
            guard let url = attachedImages[index],
                  let range = result.range(of: attachmentChar) else { continue }
            let path = GhosttyPasteboardHelper.escapeForShell(url.path)
            result = result.replacingCharacters(in: range, with: path)
        }
        return result
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
