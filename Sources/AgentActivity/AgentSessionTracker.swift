// Sources/AgentActivity/AgentSessionTracker.swift
import Foundation
import Combine

/// Manages the mapping from terminal panels to CC sessions.
///
/// Responds to socket commands (set_agent_session / clear_agent_session) to
/// register and deregister sessions. Creates ConversationLogWatchers and
/// AgentActivityStores for each active session.
final class AgentSessionTracker: ObservableObject {

    struct SessionInfo {
        let sessionId: String
        let surfaceId: String
        let cwd: String
        let jsonlPath: URL
        let store: AgentActivityStore
        var watcher: ConversationLogWatcher?
    }

    /// surfaceId (panel UUID string) → active session info
    @Published private(set) var sessions: [String: SessionInfo] = [:]

    /// The store for the currently focused panel (nil if no session)
    @Published private(set) var activeStore: AgentActivityStore? = nil

    /// Whether the sidebar should auto-show (any active session on focused panel)
    @Published private(set) var hasActiveSessionOnFocusedPanel: Bool = false

    /// Manual override for sidebar visibility (nil = auto, true = force show, false = force hide)
    @Published var sidebarManualOverride: Bool? = nil

    /// Computed sidebar visibility
    var sidebarVisible: Bool {
        sidebarManualOverride ?? hasActiveSessionOnFocusedPanel
    }

    /// Manual override for composer visibility (nil = auto, true = force show, false = force hide)
    @Published var composerManualOverride: Bool? = nil

    /// Computed composer visibility — same auto-show logic as the sidebar.
    var composerVisible: Bool {
        composerManualOverride ?? hasActiveSessionOnFocusedPanel
    }

    private var focusedSurfaceId: String?

    // MARK: - Session Registration (called from socket command handler)

    func registerSession(surfaceId: String, sessionId: String, cwd: String) {
        let projectDirHash = cwd.replacingOccurrences(of: "/", with: "-")
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(projectDirHash)
        let jsonlPath = claudeDir.appendingPathComponent("\(sessionId).jsonl")

        // If there's an existing session for this surface, clean it up
        if let existing = sessions[surfaceId] {
            existing.watcher?.stop()
            existing.store.markSessionEnded()
        }

        let store = AgentActivityStore()
        let watcher = ConversationLogWatcher(filePath: jsonlPath) { [weak store] event in
            guard let store else { return }
            switch event {
            case .toolUse(let toolEvent):
                store.appendToolUse(toolEvent)
            case .toolResult(let toolUseId, let result, let durationMs):
                store.updateToolResult(toolUseId: toolUseId, result: result, durationMs: durationMs)
            }
        }

        let info = SessionInfo(
            sessionId: sessionId,
            surfaceId: surfaceId,
            cwd: cwd,
            jsonlPath: jsonlPath,
            store: store,
            watcher: watcher
        )

        DispatchQueue.main.async { [weak self] in
            self?.sessions[surfaceId] = info
            self?.updateFocusedStore()
        }

        watcher.start()
    }

    func endSession(surfaceId: String) {
        guard let session = sessions[surfaceId] else { return }
        session.watcher?.stop()
        session.store.markSessionEnded()

        DispatchQueue.main.async { [weak self] in
            // Don't remove — keep the ended session's store so cards remain visible
            self?.sessions[surfaceId]?.watcher = nil
            self?.updateFocusedStore()
        }
    }

    // MARK: - Focus Tracking

    func updateFocusedSurface(_ surfaceId: String?) {
        let changed = focusedSurfaceId != surfaceId
        focusedSurfaceId = surfaceId

        if changed {
            // Reset manual overrides when switching panels
            sidebarManualOverride = nil
            composerManualOverride = nil
        }

        updateFocusedStore()
    }

    func toggleSidebar() {
        if let current = sidebarManualOverride {
            sidebarManualOverride = !current
        } else {
            // First manual toggle: opposite of current auto state
            sidebarManualOverride = !hasActiveSessionOnFocusedPanel
        }
    }

    func toggleComposer() {
        if let current = composerManualOverride {
            composerManualOverride = !current
        } else {
            composerManualOverride = !hasActiveSessionOnFocusedPanel
        }
    }

    // MARK: - Private

    private func updateFocusedStore() {
        let newStore = focusedSurfaceId.flatMap { sessions[$0]?.store }
        let hasSession = focusedSurfaceId.flatMap { sessions[$0] } != nil

        DispatchQueue.main.async { [weak self] in
            self?.activeStore = newStore
            self?.hasActiveSessionOnFocusedPanel = hasSession
        }
    }
}
