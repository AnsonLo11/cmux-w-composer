import Foundation
import SwiftUI

// MARK: - FileEntry

/// A file or directory surfaced in the `@`/Tab completion popup.
/// Intentionally flat: `name` is the display name (no path), and
/// `relativePath` is what gets inserted after shell-escaping.
struct FileEntry: Hashable {
    let name: String
    let relativePath: String
    let isDirectory: Bool
}

extension FileEntry: CompletionItem {
    var detail: String { relativePath }

    var tagStyle: CompletionTagStyle {
        if isDirectory {
            return CompletionTagStyle(
                label: "Dir",
                fg: Color(red: 0xF5 / 255.0, green: 0x9E / 255.0, blue: 0x0B / 255.0), // #F59E0B
                bg: Color(red: 0xF5 / 255.0, green: 0x9E / 255.0, blue: 0x0B / 255.0).opacity(0.12)
            )
        } else {
            return CompletionTagStyle(
                label: "File",
                fg: Color(red: 0x64 / 255.0, green: 0x74 / 255.0, blue: 0x8B / 255.0), // #64748B
                bg: Color(red: 0x64 / 255.0, green: 0x74 / 255.0, blue: 0x8B / 255.0).opacity(0.10)
            )
        }
    }
}

// MARK: - FileTokenDetector

/// Pure logic for detecting the `@`-token that triggers file completion.
///
/// Rules:
///   - The `@` must be preceded by whitespace / newline / start-of-string,
///     so `email@domain` does NOT trigger.
///   - No whitespace may appear between the `@` and the cursor, so once
///     the user types a space the popup closes.
///   - Path characters (slashes, dots, letters, digits) are all part of
///     the filter.
enum FileTokenDetector {
    struct Match: Equatable {
        /// Range of `@filter` in the source text (UTF-16 based, matching NSRange).
        let range: NSRange
        /// Characters between the `@` and the cursor (may be empty).
        let filter: String
    }

    /// - Parameter cursorOffset: UTF-16 offset of the cursor within `text`
    ///   (i.e. `NSRange`-style, which is what `NSTextView.selectedRange` reports).
    static func detectAtToken(in text: String, cursorOffset: Int) -> Match? {
        let ns = text as NSString
        guard cursorOffset >= 0, cursorOffset <= ns.length else { return nil }
        if cursorOffset == 0 { return nil }

        var pos = cursorOffset - 1
        while pos >= 0 {
            let unit = ns.character(at: pos)
            if let scalar = UnicodeScalar(unit),
               CharacterSet.whitespacesAndNewlines.contains(scalar) {
                // Hit whitespace before an `@` — no trigger.
                return nil
            }
            if unit == 0x40 { // '@'
                let precededByBoundary: Bool
                if pos == 0 {
                    precededByBoundary = true
                } else {
                    let before = ns.character(at: pos - 1)
                    precededByBoundary = UnicodeScalar(before)
                        .map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
                }
                guard precededByBoundary else { return nil }
                let filterRange = NSRange(location: pos + 1, length: cursorOffset - pos - 1)
                let filter = ns.substring(with: filterRange)
                let tokenRange = NSRange(location: pos, length: cursorOffset - pos)
                return Match(range: tokenRange, filter: filter)
            }
            pos -= 1
        }
        return nil
    }
}

// MARK: - FileCompletionProvider

/// Lists files/directories of a given cwd, filtered by an optional substring.
/// Synchronous — caller is responsible for dispatching off-main if the cwd
/// is large, but for typical project directories this is fast enough to run
/// inline on the main thread.
enum FileCompletionProvider {
    /// Directory names that are always skipped because they balloon listings
    /// without adding signal (vendored deps, VCS bookkeeping).
    private static let skipNames: Set<String> = [".git", "node_modules", ".DS_Store"]

    /// Cap the result list so very large directories don't flood the popup.
    private static let maxResults = 200

    /// Lists entries of `cwd` whose name contains `filter` (case-insensitive).
    /// Directories sort first, then alphabetical by locale-aware compare.
    static func list(cwd: String, filter: String) -> [FileEntry] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let names = try? fm.contentsOfDirectory(atPath: cwd) else { return [] }
        let loweredFilter = filter.lowercased()

        var results: [FileEntry] = []
        for name in names {
            if Self.skipNames.contains(name) { continue }
            if !loweredFilter.isEmpty && !name.lowercased().contains(loweredFilter) {
                continue
            }
            let full = (cwd as NSString).appendingPathComponent(name)
            var entryIsDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &entryIsDir) else { continue }
            results.append(FileEntry(
                name: name,
                relativePath: name,
                isDirectory: entryIsDir.boolValue
            ))
            if results.count >= Self.maxResults { break }
        }

        return results.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory // directories come first
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
