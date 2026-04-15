import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit tests for the pure bash-mode logic on `ComposerState`:
///   - `shouldEnterBashMode(text:)` — normalizes English '!' and full-width
///     Chinese '！', trigger only when the text is a single `!`
///   - `payloadForSending()` — adds the English '!' prefix on send when
///     bashMode is on (and never emits the full-width character, per spec)
///   - Independent history: recordBashText / historyUp cycle keeps bash and
///     chat histories separate
@MainActor
final class BashModeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ComposerState.resetAllHistoriesForTesting()
    }

    override func tearDown() {
        ComposerState.resetAllHistoriesForTesting()
        super.tearDown()
    }

    // MARK: - Trigger detection

    func testEnglishBangTriggers() {
        XCTAssertTrue(ComposerState.shouldEnterBashMode(text: "!"))
    }

    func testFullWidthBangTriggers() {
        XCTAssertTrue(ComposerState.shouldEnterBashMode(text: "\u{FF01}"))
    }

    func testMultipleCharactersDoNotTrigger() {
        XCTAssertFalse(ComposerState.shouldEnterBashMode(text: "!ls"))
        XCTAssertFalse(ComposerState.shouldEnterBashMode(text: "!!"))
    }

    func testEmptyDoesNotTrigger() {
        XCTAssertFalse(ComposerState.shouldEnterBashMode(text: ""))
    }

    func testOtherCharactersDoNotTrigger() {
        XCTAssertFalse(ComposerState.shouldEnterBashMode(text: "/"))
        XCTAssertFalse(ComposerState.shouldEnterBashMode(text: "?"))
        XCTAssertFalse(ComposerState.shouldEnterBashMode(text: "a"))
    }

    // MARK: - Payload (! prefix)

    func testPayloadAddsBangInBashMode() {
        let state = ComposerState(text: "ls -la")
        state.bashMode = true
        XCTAssertEqual(state.payloadForSending(), "!ls -la")
    }

    func testPayloadAlwaysUsesEnglishBang() {
        // Even if the user somehow typed a full-width ！ in the content,
        // the PREFIX we emit must be the English ASCII `!`.
        let state = ComposerState(text: "pwd")
        state.bashMode = true
        XCTAssertTrue(state.payloadForSending().hasPrefix("!"))
        XCTAssertFalse(state.payloadForSending().hasPrefix("\u{FF01}"))
    }

    func testPayloadHasNoBangInNormalMode() {
        let state = ComposerState(text: "hello")
        state.bashMode = false
        XCTAssertEqual(state.payloadForSending(), "hello")
    }

    // MARK: - Independent history

    func testBashHistoryIsolatedFromChatHistory() {
        ComposerState.recordSentText("chat message")
        ComposerState.recordBashText("ls")

        let bashState = ComposerState()
        bashState.bashMode = true
        XCTAssertEqual(bashState.historyUp(), "ls")

        let chatState = ComposerState()
        chatState.bashMode = false
        XCTAssertEqual(chatState.historyUp(), "chat message")
    }

    func testBashHistoryDoesNotSurfaceChatEntries() {
        ComposerState.recordSentText("chat only")
        let state = ComposerState()
        state.bashMode = true
        XCTAssertNil(state.historyUp())
    }

    func testChatHistoryDoesNotSurfaceBashEntries() {
        ComposerState.recordBashText("bash only")
        let state = ComposerState()
        state.bashMode = false
        XCTAssertNil(state.historyUp())
    }
}
