import XCTest
import AppKit
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Focus-related tests for the Composer panel.
///
/// Exercises:
///   1. Auto-focus on mount: when ComposerInputView is added to a real key window,
///      its NSTextView must become the window's firstResponder.
///   2. Steal protection: while the composer is mounted and has focus,
///      `GhosttySurfaceScrollView.isResponderInsideComposerView(window.firstResponder)`
///      must return true. That static helper is the single gate the four
///      terminal focus-reclamation paths consult before stealing focus
///      (ensureFocus / applyFirstResponderIfNeeded /
///       clearSuppressReparentFocus / reassertTerminalSurfaceFocus).
///      If this test fails, the gate is broken and the terminal will steal
///      focus from the user mid-typing.
@MainActor
final class ComposerFocusTests: XCTestCase {

    // MARK: - Fixtures

    private var window: NSWindow!
    private var composerState: ComposerState!
    private var hostingView: NSHostingView<ComposerInputView>?

    override func setUp() {
        super.setUp()
        // Force NSApp to exist so window state machinery is wired up.
        _ = NSApplication.shared

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.makeKeyAndOrderFront(nil)

        composerState = ComposerState()
    }

    override func tearDown() {
        hostingView?.removeFromSuperview()
        hostingView = nil
        composerState = nil
        window.orderOut(nil)
        window = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Mount a `ComposerInputView` inside the test window and pump the run
    /// loop long enough for SwiftUI's `updateNSView` (sync + async + 50ms
    /// deferred) to claim firstResponder on the text view.
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
        host.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 600, height: 200)
        host.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(host)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        // Drive the run loop. We rely ONLY on production's auto-focus
        // mechanism — no manual objectWillChange.send() — so this acts as a
        // regression test: if production loses the ability to claim focus
        // on mount (e.g. removing the viewDidMoveToWindow tripwire in
        // ComposerNSTextView), these tests will fail.
        let deadline = Date(timeIntervalSinceNow: 0.3)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        hostingView = host
        return host
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Tests

    /// Showing the Composer must hand firstResponder to its NSTextView.
    /// Directly mirrors the user complaint "焦点被终端视图抢回去了" — if this
    /// fails, the user's first keystroke vanishes into the terminal.
    func testTextViewBecomesFirstResponderOnMount() {
        let host = mountComposer()

        guard let textView = findTextView(in: host) else {
            XCTFail("ComposerInputView did not produce an NSTextView in its hierarchy")
            return
        }

        let fr = window.firstResponder
        let isComposerFR =
            fr === textView ||
            ((fr as? NSView).map { $0.isDescendant(of: textView) } ?? false)

        XCTAssertTrue(
            isComposerFR,
            "After mounting Composer, window.firstResponder should be the composer NSTextView. " +
            "Got: \(String(describing: fr))"
        )
    }

    /// The four terminal focus-reclamation paths in `GhosttySurfaceScrollView`
    /// (ensureFocus, applyFirstResponderIfNeeded, clearSuppressReparentFocus,
    /// reassertTerminalSurfaceFocus) bail out early when
    /// `isResponderInsideComposerView(window.firstResponder)` returns true.
    /// If this returns false while the composer is up, the terminal will
    /// steal focus and the user's typing vanishes.
    func testFocusReclamationGuardRecognizesActiveComposer() {
        mountComposer()

        guard let fr = window.firstResponder else {
            XCTFail("Window had no firstResponder after mounting Composer")
            return
        }

        XCTAssertTrue(
            GhosttySurfaceScrollView.isResponderInsideComposerView(fr),
            "Focus-reclamation gate must recognize the composer's text view as " +
            "'inside composer'. Otherwise the terminal will steal focus mid-typing. " +
            "firstResponder=\(String(describing: fr))"
        )
    }

    /// Sanity check: the gate must NOT misfire on unrelated views — otherwise
    /// it would falsely block legitimate terminal focus reclamation when no
    /// composer is mounted.
    func testFocusReclamationGuardRejectsUnrelatedView() {
        let unrelated = NSView()
        XCTAssertFalse(
            GhosttySurfaceScrollView.isResponderInsideComposerView(unrelated),
            "Gate must not flag unrelated NSViews as belonging to the Composer"
        )
    }

    /// End-to-end check on the steal protection: simulate the production
    /// reclamation path. Production checks the gate, and bails. If we follow
    /// the same logic here, the composer keeps focus.
    func testTerminalReclamationLeavesComposerFocusedWhenComposerIsActive() {
        let host = mountComposer()

        guard let textView = findTextView(in: host) else {
            XCTFail("Could not locate composer NSTextView")
            return
        }

        // Simulate one tick of the production focus-reclamation flow.
        // Production: `if let fr = window.firstResponder, Self.isResponderInsideComposerView(fr) { return }`
        let fr = window.firstResponder
        let wouldSteal: Bool = {
            guard let fr else { return true }
            return !GhosttySurfaceScrollView.isResponderInsideComposerView(fr)
        }()

        XCTAssertFalse(
            wouldSteal,
            "Production reclamation path should NOT steal focus while composer is mounted. " +
            "Gate result for fr=\(String(describing: fr)) was 'would steal'."
        )
        // And focus should still actually be on the composer.
        XCTAssertTrue(
            window.firstResponder === textView ||
                ((window.firstResponder as? NSView)?.isDescendant(of: textView) ?? false),
            "Composer text view must still own firstResponder after the gate-respecting tick"
        )
    }
}
