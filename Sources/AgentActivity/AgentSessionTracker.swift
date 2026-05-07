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

    func updateFocusedSurface(_ surfaceId: String?, cwd: String? = nil) {
        let changed = focusedSurfaceId != surfaceId
        focusedSurfaceId = surfaceId

        if changed {
            sidebarManualOverride = nil
            composerManualOverride = nil
        }

        // If the focused panel has no registered session, try to discover
        // an existing CC session by scanning JSONL files for this CWD.
        if let surfaceId, sessions[surfaceId] == nil, let cwd, !cwd.isEmpty {
            discoverExistingSession(surfaceId: surfaceId, cwd: cwd)
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

    // MARK: - Session Discovery (fallback for old sessions without hooks)

    /// Surfaces that we already attempted discovery for, to avoid repeated scans.
    private var discoveryAttempted: Set<String> = []

    /// Try to find an active CC session by scanning JSONL files for this CWD.
    /// Called when a panel is focused but has no registered session.
    private func discoverExistingSession(surfaceId: String, cwd: String) {
        guard !discoveryAttempted.contains(surfaceId) else { return }
        discoveryAttempted.insert(surfaceId)

        let projectDirHash = cwd.replacingOccurrences(of: "/", with: "-")
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(projectDirHash)

        // Scan on a background queue to avoid blocking main
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let jsonlFile = Self.findMostRecentActiveJSONL(in: claudeDir) else { return }

            let sessionId = jsonlFile.deletingPathExtension().lastPathComponent

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Double-check: another registration may have arrived via hook
                guard self.sessions[surfaceId] == nil else { return }
                self.registerSession(surfaceId: surfaceId, sessionId: sessionId, cwd: cwd)
            }
        }
    }

    /// Find the most recently modified `.jsonl` file in the directory that is
    /// still being actively written (modified within the last 60 seconds).
    private static func findMostRecentActiveJSONL(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        let now = Date()
        let cutoff: TimeInterval = 60 // consider "active" if modified within 60s

        return contents
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modDate = values.contentModificationDate,
                      now.timeIntervalSince(modDate) < cutoff else { return nil }
                return (url, modDate)
            }
            .max(by: { $0.1 < $1.1 })
            .map(\.0)
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
