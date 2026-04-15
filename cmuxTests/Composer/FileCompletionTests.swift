import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit tests for the pure logic behind `@`-triggered file completion:
///
///   1. `FileTokenDetector.detectAtToken(in:cursorOffset:)` – walks back from the
///      cursor to find the nearest `@` that's preceded by whitespace / newline /
///      start-of-string, with no intervening whitespace between the `@` and the
///      cursor. This is what decides whether the popup appears and what the
///      filter string is.
///
///   2. `FileCompletionProvider.list(cwd:filter:)` – lists entries of a
///      directory, case-insensitively filtered, skipping git/node_modules
///      sentinels.
///
///   3. `FileEntry` conformance to `CompletionItem`.
final class FileCompletionTests: XCTestCase {

    // MARK: - Token detection

    func testNoAtSymbolReturnsNil() {
        XCTAssertNil(FileTokenDetector.detectAtToken(in: "hello world", cursorOffset: 11))
    }

    func testAtAtStartTriggers() {
        let match = FileTokenDetector.detectAtToken(in: "@", cursorOffset: 1)
        XCTAssertEqual(match?.filter, "")
        XCTAssertEqual(match?.range, NSRange(location: 0, length: 1))
    }

    func testAtAfterSpaceTriggers() {
        let match = FileTokenDetector.detectAtToken(in: "hello @foo", cursorOffset: 10)
        XCTAssertEqual(match?.filter, "foo")
        XCTAssertEqual(match?.range, NSRange(location: 6, length: 4))
    }

    func testAtAfterNewlineTriggers() {
        let match = FileTokenDetector.detectAtToken(in: "line1\n@bar", cursorOffset: 10)
        XCTAssertEqual(match?.filter, "bar")
    }

    func testAtInsideWordDoesNotTrigger() {
        // email@domain should NOT trigger — @ is not preceded by whitespace.
        XCTAssertNil(FileTokenDetector.detectAtToken(in: "email@domain", cursorOffset: 12))
    }

    func testSpaceAfterAtBreaksToken() {
        // Cursor after the space: token is considered closed.
        XCTAssertNil(FileTokenDetector.detectAtToken(in: "@foo bar", cursorOffset: 8))
    }

    func testCursorInsideFilterTriggers() {
        // Cursor between 'f' and 'o' of "@foo" — filter is "f".
        let match = FileTokenDetector.detectAtToken(in: "@foo", cursorOffset: 2)
        XCTAssertEqual(match?.filter, "f")
        XCTAssertEqual(match?.range, NSRange(location: 0, length: 2))
    }

    func testPathCharactersStayInFilter() {
        // Slashes and dots in paths are part of the filter token.
        let match = FileTokenDetector.detectAtToken(in: "@src/Foo.swift", cursorOffset: 14)
        XCTAssertEqual(match?.filter, "src/Foo.swift")
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(FileTokenDetector.detectAtToken(in: "", cursorOffset: 0))
    }

    // MARK: - Bash word-before-cursor detection (used by Tab completion)

    func testBashWordAtStartIsEmpty() {
        let match = FileTokenDetector.detectWordBeforeCursor(in: "", cursorOffset: 0)
        XCTAssertEqual(match?.range, NSRange(location: 0, length: 0))
        XCTAssertEqual(match?.word, "")
    }

    func testBashWordAfterSpaceIsEmpty() {
        // Cursor right after a space — word is empty, range is at cursor.
        let match = FileTokenDetector.detectWordBeforeCursor(in: "cat ", cursorOffset: 4)
        XCTAssertEqual(match?.word, "")
        XCTAssertEqual(match?.range, NSRange(location: 4, length: 0))
    }

    func testBashWordGrabsTokenBeforeCursor() {
        let match = FileTokenDetector.detectWordBeforeCursor(in: "cat READ", cursorOffset: 8)
        XCTAssertEqual(match?.word, "READ")
        XCTAssertEqual(match?.range, NSRange(location: 4, length: 4))
    }

    func testBashWordAtLineStart() {
        let match = FileTokenDetector.detectWordBeforeCursor(in: "ls", cursorOffset: 2)
        XCTAssertEqual(match?.word, "ls")
        XCTAssertEqual(match?.range, NSRange(location: 0, length: 2))
    }

    func testBashWordHandlesNewline() {
        let match = FileTokenDetector.detectWordBeforeCursor(in: "cd\nREAD", cursorOffset: 7)
        XCTAssertEqual(match?.word, "READ")
        XCTAssertEqual(match?.range, NSRange(location: 3, length: 4))
    }

    // MARK: - File listing

    func testListReturnsEntriesForTmpDir() throws {
        let dir = try makeScratchDir(["apple.txt", "banana.txt", "cherry.md"])
        let entries = FileCompletionProvider.list(cwd: dir.path, filter: "")
        let names = Set(entries.map(\.name))
        XCTAssertEqual(names, ["apple.txt", "banana.txt", "cherry.md"])
    }

    func testFilterIsCaseInsensitive() throws {
        let dir = try makeScratchDir(["README.md", "LICENSE"])
        let entries = FileCompletionProvider.list(cwd: dir.path, filter: "read")
        XCTAssertEqual(entries.map(\.name), ["README.md"])
    }

    func testDotGitIsSkipped() throws {
        let dir = try makeScratchDir(["a.txt"])
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let entries = FileCompletionProvider.list(cwd: dir.path, filter: "")
        XCTAssertFalse(entries.contains { $0.name == ".git" })
    }

    func testDirectoryTagStyleDiffersFromFile() {
        let dirEntry = FileEntry(name: "src", relativePath: "src", isDirectory: true)
        let fileEntry = FileEntry(name: "README.md", relativePath: "README.md", isDirectory: false)
        XCTAssertEqual(dirEntry.tagStyle.label, "Dir")
        XCTAssertEqual(fileEntry.tagStyle.label, "File")
        XCTAssertNotEqual(dirEntry.tagStyle, fileEntry.tagStyle)
    }

    // MARK: - Helpers

    private func makeScratchDir(_ files: [String]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-filecompletion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for f in files {
            FileManager.default.createFile(
                atPath: base.appendingPathComponent(f).path,
                contents: Data()
            )
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: base)
        }
        return base
    }
}
