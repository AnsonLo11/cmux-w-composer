import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit tests for code-block logic in ComposerState:
///   - `parseFenceLine()` — fence trigger detection for ```, ～～～, ···
///   - `textWithCodeFencesApplied(to:)` — serialization to markdown fences
///   - `CodeBlockSpan` tracking
@MainActor
final class CodeBlockTests: XCTestCase {

    // MARK: - parseFenceLine

    func testBacktickFenceNoLanguage() {
        XCTAssertEqual(ComposerState.parseFenceLine("```"), "")
    }

    func testBacktickFenceWithLanguage() {
        XCTAssertEqual(ComposerState.parseFenceLine("```python"), "python")
    }

    func testBacktickFenceWithLanguageRust() {
        XCTAssertEqual(ComposerState.parseFenceLine("```rust"), "rust")
    }

    func testFullWidthTildeFence() {
        // U+FF5E × 3
        XCTAssertEqual(ComposerState.parseFenceLine("～～～"), "")
    }

    func testMiddleDotFence() {
        // U+00B7 × 3
        XCTAssertEqual(ComposerState.parseFenceLine("···"), "")
    }

    func testMiddleDotFenceWithLanguage() {
        XCTAssertEqual(ComposerState.parseFenceLine("···swift"), "swift")
    }

    func testTwoBackticksNotEnough() {
        XCTAssertNil(ComposerState.parseFenceLine("``"))
    }

    func testMixedFenceCharsRejected() {
        // First char backtick, second tilde — not all same char
        XCTAssertNil(ComposerState.parseFenceLine("`～`"))
    }

    func testFenceWithWhitespaceInLanguageRejected() {
        XCTAssertNil(ComposerState.parseFenceLine("```py thon"))
    }

    func testPlainTextNotFence() {
        XCTAssertNil(ComposerState.parseFenceLine("hello world"))
    }

    func testEmptyStringNotFence() {
        XCTAssertNil(ComposerState.parseFenceLine(""))
    }

    func testSingleBacktickNotFence() {
        XCTAssertNil(ComposerState.parseFenceLine("`"))
    }

    func testFourBackticksStillMatch() {
        // Only first 3 checked, rest is "language"
        XCTAssertEqual(ComposerState.parseFenceLine("````"), "`")
    }

    // MARK: - textWithCodeFencesApplied

    func testNoCodeBlocks() {
        let state = ComposerState(text: "hello world")
        // No code blocks → text unchanged
        XCTAssertEqual(state.textWithCodeFencesApplied(to: "hello world"), "hello world")
    }

    func testSingleCodeBlock() {
        // "import os" at [7,16) is code; the \n at position 16 is prose.
        // Serialization: closing fence \n + prose \n → two newlines.
        let state = ComposerState(text: "before\nimport os\nafter")
        state.codeBlocks = [
            ComposerState.CodeBlockSpan(
                range: NSRange(location: 7, length: 9), // "import os"
                language: "python"
            )
        ]
        let result = state.textWithCodeFencesApplied(to: state.text)
        XCTAssertEqual(result, "before\n```python\nimport os\n```\n\nafter")
    }

    func testEmptyCodeBlock() {
        let state = ComposerState(text: "before\n\nafter")
        state.codeBlocks = [
            ComposerState.CodeBlockSpan(
                range: NSRange(location: 7, length: 0),
                language: ""
            )
        ]
        // Empty range filtered out by textWithCodeFencesApplied
        // (length == 0 → range.length >= 0 passes but substring is "").
        // An empty content still emits a fenced block: ```\n\n```\n
        let result = state.textWithCodeFencesApplied(to: state.text)
        XCTAssertEqual(result, "before\n```\n\n```\n\nafter")
    }

    func testCodeBlockWithNewlineContent() {
        let text = "import os\nimport sys\n"
        let state = ComposerState(text: text)
        state.codeBlocks = [
            ComposerState.CodeBlockSpan(
                range: NSRange(location: 0, length: (text as NSString).length),
                language: "python"
            )
        ]
        let result = state.textWithCodeFencesApplied(to: state.text)
        XCTAssertEqual(result, "```python\nimport os\nimport sys\n```\n")
    }

    func testCodeBlockNoLanguage() {
        let state = ComposerState(text: "x = 1")
        state.codeBlocks = [
            ComposerState.CodeBlockSpan(
                range: NSRange(location: 0, length: 5),
                language: ""
            )
        ]
        let result = state.textWithCodeFencesApplied(to: state.text)
        XCTAssertEqual(result, "```\nx = 1\n```\n")
    }

    func testMultipleCodeBlocks() {
        // prose(6) \n code1(5) \n prose2(6) \n code2(5) \n end(3)
        // code1 at [6,11), code2 at [19,24)
        // Prose \n between code and prose → extra newlines in output.
        let state = ComposerState(text: "prose\ncode1\nprose2\ncode2\nend")
        state.codeBlocks = [
            ComposerState.CodeBlockSpan(
                range: NSRange(location: 6, length: 5), // "code1"
                language: "js"
            ),
            ComposerState.CodeBlockSpan(
                range: NSRange(location: 19, length: 5), // "code2"
                language: ""
            ),
        ]
        let result = state.textWithCodeFencesApplied(to: state.text)
        XCTAssertEqual(result, "prose\n```js\ncode1\n```\n\nprose2\n```\ncode2\n```\n\nend")
    }

    // MARK: - Payload integration (bash + code fences)

    func testPayloadWithCodeBlocksNoBash() {
        let state = ComposerState(text: "say\nhello\nworld")
        state.codeBlocks = [
            ComposerState.CodeBlockSpan(
                range: NSRange(location: 4, length: 5), // "hello"
                language: "txt"
            )
        ]
        let payload = state.payloadForSending()
        XCTAssertTrue(payload.contains("```txt"))
        XCTAssertTrue(payload.contains("hello"))
        XCTAssertFalse(payload.hasPrefix("!"))
    }

    func testPayloadWithBashModeAndCodeBlocks() {
        let state = ComposerState(text: "echo hi")
        state.bashMode = true
        state.codeBlocks = []
        let payload = state.payloadForSending()
        XCTAssertTrue(payload.hasPrefix("!"))
        XCTAssertTrue(payload.contains("echo hi"))
    }

    // MARK: - codeBlockFenceCharacters

    func testFenceCharactersContainExpectedChars() {
        let chars = ComposerState.codeBlockFenceCharacters
        XCTAssertTrue(chars.contains(Character("\u{0060}")))  // backtick
        XCTAssertTrue(chars.contains(Character("\u{FF5E}")))  // fullwidth tilde
        XCTAssertTrue(chars.contains(Character("\u{00B7}")))  // middle dot
    }
}
