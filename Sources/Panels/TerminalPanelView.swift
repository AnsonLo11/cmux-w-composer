import SwiftUI
import Foundation
import AppKit
import Bonsplit

/// View for rendering a terminal panel
struct TerminalPanelView: View {
    @ObservedObject var panel: TerminalPanel
    @AppStorage(NotificationPaneRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let onFocus: () -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Layering contract: terminal find UI is mounted in GhosttySurfaceScrollView (AppKit portal layer)
            // via `searchState`. Rendering `SurfaceSearchOverlay` in this SwiftUI container can hide it.
            GhosttyTerminalView(
                terminalSurface: panel.surface,
                paneId: paneId,
                isActive: isFocused,
                isVisibleInUI: isVisibleInUI,
                portalZPriority: portalPriority,
                showsInactiveOverlay: isSplit && !isFocused,
                showsUnreadNotificationRing: hasUnreadNotification && notificationPaneRingEnabled,
                inactiveOverlayColor: appearance.unfocusedOverlayNSColor,
                inactiveOverlayOpacity: appearance.unfocusedOverlayOpacity,
                searchState: panel.searchState,
                isComposerActive: panel.composerState != nil,
                reattachToken: panel.viewReattachToken,
                onFocus: { _ in onFocus() },
                onTriggerFlash: onTriggerFlash
            )
            // Keep the NSViewRepresentable identity stable across bonsplit structural updates.
            // This prevents transient teardown/recreate that can momentarily detach the hosted terminal view.
            .id(panel.id)
            .background(Color.clear)

            // Composer panel — renders below the terminal, not as an overlay.
            // The terminal shrinks to make room when the composer is visible.
            if let composerState = panel.composerState {
                ComposerInputView(
                    composerState: composerState,
                    onSend: { [weak surface = panel.surface] _ in
                        guard let surface else { return }
                        NotificationCenter.default.post(
                            name: .cmuxComposerDidSend,
                            object: surface
                        )
                    },
                    onDismiss: { [weak surface = panel.surface] in
                        guard let surface else { return }
                        NotificationCenter.default.post(
                            name: .cmuxComposerDidDismiss,
                            object: surface
                        )
                    },
                    onTextViewBecameFirstResponder: { [weak surface = panel.surface] in
                        surface?.setFocus(false)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// Shared appearance settings for panels
struct PanelAppearance {
    let dividerColor: Color
    let unfocusedOverlayNSColor: NSColor
    let unfocusedOverlayOpacity: Double

    static func fromConfig(_ config: GhosttyConfig) -> PanelAppearance {
        PanelAppearance(
            dividerColor: Color(nsColor: config.resolvedSplitDividerColor),
            unfocusedOverlayNSColor: config.unfocusedSplitOverlayFill,
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity
        )
    }
}
