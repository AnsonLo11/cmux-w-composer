import XCTest
import AppKit
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Dismiss-related tests for the Composer panel.
///
/// In production, dismissing the Composer (Esc, ⌘⇧I again, or send) sets
/// `TerminalPanel.composerState = nil`, which causes SwiftUI to drop the
/// `ComposerInputView` from the view hierarchy. Once the composer is gone,
/// the four terminal focus-reclamation paths in `GhosttySurfaceScrollView`
/// stop bailing on `composerIsActive`/`isResponderInsideComposerView`, and
/// reclaim firstResponder for the terminal surface.
///
/// These tests exercise the parts that don't require a full Ghostty surface:
///   1. After the composer's hosting view is removed from its window, no
///      view "inside composer" can still own firstResponder.
///   2. A sibling view (acting as the terminal stand-in) can become
///      firstResponder after dismiss — i.e. the focus path is unblocked.
@MainActor
final class ComposerDismissTests: XCTestCase {

    // MARK: - Fixtures

    private var window: NSWindow!
    private var contentView: NSView!
    private var terminalStandIn: TerminalLikeView!
    private var composerState: ComposerState!
    private var hostingView: NSHostingView<ComposerInputView>?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = contentView

        // The terminal stand-in lives side-by-side with the composer so that
        // after dismiss it can be made firstResponder — mimicking what
        // GhosttySurfaceScrollView.reassertTerminalSurfaceFocus does in prod.
        terminalStandIn = TerminalLikeView(frame: NSRect(x: 0, y: 200, width: 600, height: 200))
        contentView.addSubview(terminalStandIn)

        window.makeKeyAndOrderFront(nil)
        // Park initial focus on the terminal stand-in so we can verify the
        // round-trip: terminal → composer (mount) → terminal (dismiss).
        _ = window.makeFirstResponder(terminalStandIn)

        composerState = ComposerState()
    }

    override func tearDown() {
        hostingView?.removeFromSuperview()
        hostingView = nil
        composerState = nil
        terminalStandIn = nil
        contentView = nil
        window.orderOut(nil)
        window = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func mountComposer() -> NSHostingView<ComposerInputView> {
        let view = ComposerInputView(
            composerState: composerState,
            onSend: { _ in },
            onSendAndSubmit: { _ in },
            onDismiss: { },
            onTextViewBecameFirstResponder: { }
        )
        let host = NSHostingView(rootView: view)
        // Mount the composer in the lower half so the terminal stand-in is
        // still visible at the top — matches the production layout where the
        // terminal sits above and the composer below.
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        host.autoresizingMask = [.width]
        contentView.addSubview(host)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        // No manual objectWillChange.send() — rely entirely on production's
        // auto-focus mechanism (makeNSView arms the viewDidMoveToWindow
        // tripwire on ComposerNSTextView). If that mechanism regresses,
        // these tests fail.
        let deadline = Date(timeIntervalSinceNow: 0.3)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        hostingView = host
        return host
    }

    private func dismissComposer() {
        // Production drops ComposerInputView from the SwiftUI hierarchy when
        // composerState becomes nil. Removing the hosting view from its
        // superview is the AppKit-level equivalent.
        hostingView?.removeFromSuperview()
        hostingView = nil
        // Pump the run loop so any deferred bookkeeping settles.
        let deadline = Date(timeIntervalSinceNow: 0.05)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Tests

    /// After dismiss, no remaining firstResponder should still be classified
    /// as "inside composer". If this fails the focus-reclamation gate would
    /// keep blocking terminal focus restoration after the composer is gone.
    func testFirstResponderIsNoLongerInsideComposerAfterDismiss() {
        let host = mountComposer()
        guard findTextView(in: host) != nil else {
            XCTFail("Setup failure — composer text view not found")
            return
        }

        dismissComposer()

        if let fr = window.firstResponder {
            XCTAssertFalse(
                GhosttySurfaceScrollView.isResponderInsideComposerView(fr),
                "After dismissing the composer, no responder in the chain should be 'inside composer'. " +
                "Got fr=\(String(describing: fr))"
            )
        }
        // (No firstResponder at all is also acceptable — the next focus path
        // tick in production will then claim the terminal surface.)
    }

    /// After dismiss, the terminal stand-in must be able to become the
    /// firstResponder. In production this is what
    /// `GhosttySurfaceScrollView.reassertTerminalSurfaceFocus` does once
    /// `composerIsActive` clears.
    func testTerminalStandInRegainsFirstResponderAfterDismiss() {
        mountComposer()
        dismissComposer()

        let success = window.makeFirstResponder(terminalStandIn)
        XCTAssertTrue(
            success,
            "Terminal stand-in must accept firstResponder after the composer dismiss path settles"
        )
        XCTAssertTrue(
            window.firstResponder === terminalStandIn,
            "After dismiss, window.firstResponder should be the terminal stand-in. " +
            "Got: \(String(describing: window.firstResponder))"
        )
    }

    /// Round-trip sanity: terminal → composer mount → composer dismiss →
    /// terminal. The intermediate state must show the composer holding
    /// focus, and the final state must restore it to the terminal.
    func testFocusRoundTripTerminalToComposerAndBack() {
        // Initial: terminal owns focus (set in setUp).
        XCTAssertTrue(
            window.firstResponder === terminalStandIn,
            "Pre-mount: terminal stand-in should own firstResponder"
        )

        // Mount composer → composer must own focus.
        let host = mountComposer()
        guard let textView = findTextView(in: host) else {
            XCTFail("Could not locate composer NSTextView")
            return
        }
        let frAfterMount = window.firstResponder
        XCTAssertTrue(
            frAfterMount === textView ||
                ((frAfterMount as? NSView)?.isDescendant(of: textView) ?? false),
            "After mount: firstResponder should be the composer text view. " +
            "Got: \(String(describing: frAfterMount))"
        )

        // Dismiss → terminal should accept focus again.
        dismissComposer()
        XCTAssertTrue(
            window.makeFirstResponder(terminalStandIn),
            "After dismiss: terminal stand-in should accept firstResponder"
        )
        XCTAssertTrue(window.firstResponder === terminalStandIn)
    }
}

// MARK: - Test fixtures

/// A minimal stand-in for `GhosttyNSView`/`GhosttySurfaceScrollView`'s
/// `surfaceView`. We only need acceptsFirstResponder semantics; the actual
/// terminal surface requires Ghostty initialization, which is too heavy for
/// a unit test.
private final class TerminalLikeView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override func resignFirstResponder() -> Bool { true }
}
