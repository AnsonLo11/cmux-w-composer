# Agent Activity Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only sidebar that shows structured Claude Code tool executions (Bash, Read, Write, Edit, Grep, Glob, Agent) for the focused terminal panel, parsed from CC conversation JSONL files.

**Architecture:** Data flows from CC's conversation JSONL → incremental file watcher → parsed ToolEvents → SwiftUI card list. Session mapping uses the existing cmux claude-hook infrastructure (session-start/end hooks already store sessionId + surfaceId + cwd in `~/.cmuxterm/claude-hook-sessions.json`). The sidebar is a fixed right panel outside Bonsplit, added via HStack in `WorkspaceContentView`.

**Tech Stack:** Swift, SwiftUI, AppKit (DispatchSource for file watching), Combine (@Published), existing cmux socket command infrastructure.

**Design Spec:** `docs/superpowers/specs/2026-04-22-agent-activity-sidebar-design.md`

---

## File Structure

```
Sources/AgentActivity/              ← NEW directory
├── ToolEvent.swift                 ← Data model: ToolEvent, ToolType, ToolInput, ToolResult
├── ConversationLogWatcher.swift    ← JSONL file monitoring + incremental parsing
├── AgentActivityStore.swift        ← Per-session event store + filter logic
├── AgentSessionTracker.swift       ← Panel→session mapping, watcher lifecycle
├── AgentActivitySidebar.swift      ← Sidebar container view (header, filter, scroll, empty state)
└── Cards/
    ├── ToolCardShell.swift         ← Shared card outer shell (color bar, timestamp, expand/collapse)
    ├── BashCardView.swift          ← Bash command + output card
    ├── FileOpCardView.swift        ← Read/Write/Edit card (shared with per-type specialization)
    ├── SearchCardView.swift        ← Grep/Glob card (shared)
    └── AgentCardView.swift         ← Sub-agent card
```

**Existing files modified:**

| File | Change |
|------|--------|
| `CLI/cmux.swift` | Add `set_agent_session` socket command in session-start hook to send sessionId+cwd to app |
| `Sources/TerminalController.swift` | Add `set_agent_session` / `clear_agent_session` command handlers |
| `Sources/Workspace.swift` | Add `agentSessionTracker: AgentSessionTracker` property |
| `Sources/WorkspaceContentView.swift` | HStack wrapping BonsplitView + sidebar |
| `Sources/KeyboardShortcutSettings.swift` | Register `.toggleAgentSidebar` action |
| `Resources/Localizable.xcstrings` | New UI strings (en + ja) |
| `GhosttyTabs.xcodeproj/project.pbxproj` | Register all new source files |

---

### Task 1: Data Model — ToolEvent.swift

**Files:**
- Create: `Sources/AgentActivity/ToolEvent.swift`

- [ ] **Step 1: Create ToolEvent.swift with all data types**

```swift
// Sources/AgentActivity/ToolEvent.swift
import Foundation

enum ToolType: String, CaseIterable, Identifiable {
    case bash = "Bash"
    case read = "Read"
    case write = "Write"
    case edit = "Edit"
    case grep = "Grep"
    case glob = "Glob"
    case agent = "Agent"
    case other = "Other"

    var id: String { rawValue }

    var sfSymbol: String {
        switch self {
        case .bash: return "terminal"
        case .read: return "doc.text"
        case .write: return "doc.badge.plus"
        case .edit: return "pencil.line"
        case .grep: return "magnifyingglass"
        case .glob: return "folder.badge.magnifyingglass"
        case .agent: return "person.2"
        case .other: return "questionmark.circle"
        }
    }

    var accentColorName: String {
        switch self {
        case .bash: return "cyan"
        case .read: return "blue"
        case .write: return "green"
        case .edit: return "yellow"
        case .grep: return "purple"
        case .glob: return "indigo"
        case .agent: return "orange"
        case .other: return "gray"
        }
    }

    init(rawToolName: String) {
        self = ToolType(rawValue: rawToolName) ?? .other
    }
}

enum ToolInput {
    case bash(command: String, description: String?)
    case read(filePath: String, limit: Int?, offset: Int?)
    case write(filePath: String)
    case edit(filePath: String, oldString: String, newString: String)
    case grep(pattern: String, path: String?, glob: String?)
    case glob(pattern: String, path: String?)
    case agent(description: String, prompt: String?)
    case unknown(raw: [String: Any])

    /// Human-readable summary for the card header
    var summary: String {
        switch self {
        case .bash(let command, _):
            return command
        case .read(let filePath, _, _):
            return filePath
        case .write(let filePath):
            return filePath
        case .edit(let filePath, _, _):
            return filePath
        case .grep(let pattern, let path, _):
            let pathSuffix = path.map { " in \($0)" } ?? ""
            return "\(pattern)\(pathSuffix)"
        case .glob(let pattern, _):
            return pattern
        case .agent(let description, _):
            return description
        case .unknown:
            return "(unknown)"
        }
    }

    static func parse(toolName: String, input: [String: Any]) -> ToolInput {
        switch toolName {
        case "Bash":
            return .bash(
                command: input["command"] as? String ?? "",
                description: input["description"] as? String
            )
        case "Read":
            return .read(
                filePath: input["file_path"] as? String ?? "",
                limit: input["limit"] as? Int,
                offset: input["offset"] as? Int
            )
        case "Write":
            return .write(filePath: input["file_path"] as? String ?? "")
        case "Edit":
            return .edit(
                filePath: input["file_path"] as? String ?? "",
                oldString: input["old_string"] as? String ?? "",
                newString: input["new_string"] as? String ?? ""
            )
        case "Grep":
            return .grep(
                pattern: input["pattern"] as? String ?? "",
                path: input["path"] as? String,
                glob: input["glob"] as? String
            )
        case "Glob":
            return .glob(
                pattern: input["pattern"] as? String ?? "",
                path: input["path"] as? String
            )
        case "Agent":
            return .agent(
                description: input["description"] as? String ?? "",
                prompt: input["prompt"] as? String
            )
        default:
            return .unknown(raw: input)
        }
    }
}

enum ToolResult {
    case success(content: String, truncated: Bool)
    case error(message: String)

    var content: String {
        switch self {
        case .success(let content, _): return content
        case .error(let message): return message
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

struct ToolEvent: Identifiable {
    let id: String          // tool_use_id (e.g. "toolu_xxx")
    let toolType: ToolType
    let timestamp: Date
    let input: ToolInput
    var result: ToolResult? // nil while executing
    var durationMs: Int?

    var isExecuting: Bool { result == nil }
}
```

- [ ] **Step 2: Verify file compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-sidebar build 2>&1 | grep -E '(BUILD|error:)'
```

Note: This will fail until the file is added to pbxproj. That happens in a later task. For now, verify the Swift syntax is valid by checking no Swift parse errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/AgentActivity/ToolEvent.swift
git commit -m "feat(agent-activity): add ToolEvent data model

ToolType enum with SF symbol and color mappings, ToolInput with
per-tool-type parsing, ToolResult, and ToolEvent struct."
```

---

### Task 2: JSONL Parser — ConversationLogWatcher.swift

**Files:**
- Create: `Sources/AgentActivity/ConversationLogWatcher.swift`

- [ ] **Step 1: Create ConversationLogWatcher with incremental JSONL parsing**

```swift
// Sources/AgentActivity/ConversationLogWatcher.swift
import Foundation

/// Watches a CC conversation JSONL file for changes and emits parsed ToolEvents.
///
/// Uses DispatchSource (EVFILT_VNODE) to detect writes, reads new bytes from the
/// last-known offset, splits by newline, and parses each line as JSON looking for
/// tool_use and tool_result content blocks.
final class ConversationLogWatcher {

    enum Event {
        case toolUse(ToolEvent)
        case toolResult(toolUseId: String, result: ToolResult, durationMs: Int?)
    }

    private let filePath: URL
    private let onEvent: (Event) -> Void
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var byteOffset: UInt64 = 0
    private let queue = DispatchQueue(label: "com.cmux.conversation-log-watcher", qos: .utility)

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(filePath: URL, onEvent: @escaping (Event) -> Void) {
        self.filePath = filePath
        self.onEvent = onEvent
    }

    deinit {
        stop()
    }

    /// Start watching. If the file already exists, parse existing content first.
    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }
    }

    // MARK: - Private

    private func startOnQueue() {
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            watchForFileCreation()
            return
        }
        attachToFile()
    }

    /// If the JSONL file doesn't exist yet (CC just started), watch the parent directory
    /// for its creation, then attach.
    private func watchForFileCreation() {
        let dirPath = filePath.deletingLastPathComponent().path
        guard let dirFD = open(dirPath, O_EVTONLY) as Int32?,
              dirFD >= 0 else { return }

        let dirSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: .write,
            queue: queue
        )
        dirSource.setEventHandler { [weak self] in
            guard let self,
                  FileManager.default.fileExists(atPath: self.filePath.path) else { return }
            dirSource.cancel()
            close(dirFD)
            self.attachToFile()
        }
        dirSource.setCancelHandler {
            close(dirFD)
        }
        dirSource.resume()
    }

    private func attachToFile() {
        guard let handle = FileHandle(forReadingAtPath: filePath.path) else { return }
        self.fileHandle = handle

        // Parse any existing content
        readNewContent()

        // Watch for future writes
        let fd = handle.fileDescriptor
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.readNewContent()
        }
        src.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }
        src.resume()
        self.source = src
    }

    private func readNewContent() {
        guard let handle = fileHandle else { return }
        handle.seek(toFileOffset: byteOffset)
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        byteOffset += UInt64(data.count)

        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            parseLine(trimmed)
        }
    }

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let contentArray = message["content"] as? [[String: Any]] else {
            return
        }

        let timestamp = (json["timestamp"] as? String)
            .flatMap { Self.iso8601Formatter.date(from: $0) } ?? Date()

        for content in contentArray {
            guard let contentType = content["type"] as? String else { continue }

            if contentType == "tool_use" {
                parseToolUse(content: content, timestamp: timestamp)
            } else if contentType == "tool_result" {
                parseToolResult(
                    content: content,
                    toolUseResult: json["toolUseResult"] as? [String: Any]
                )
            }
        }
    }

    private func parseToolUse(content: [String: Any], timestamp: Date) {
        guard let toolUseId = content["id"] as? String,
              let toolName = content["name"] as? String,
              let input = content["input"] as? [String: Any] else { return }

        let event = ToolEvent(
            id: toolUseId,
            toolType: ToolType(rawToolName: toolName),
            timestamp: timestamp,
            input: ToolInput.parse(toolName: toolName, input: input),
            result: nil,
            durationMs: nil
        )
        onEvent(.toolUse(event))
    }

    private func parseToolResult(content: [String: Any], toolUseResult: [String: Any]?) {
        guard let toolUseId = content["tool_use_id"] as? String else { return }

        let durationMs = toolUseResult?["durationMs"] as? Int

        let result: ToolResult
        if let isError = content["is_error"] as? Bool, isError {
            let errorContent = extractTextContent(from: content["content"])
            result = .error(message: errorContent)
        } else {
            let textContent = extractTextContent(from: content["content"])
            let truncated = toolUseResult?["truncated"] as? Bool ?? false
            // Truncate very large outputs for display (50KB limit)
            let maxDisplayLength = 50_000
            if textContent.count > maxDisplayLength {
                let truncatedContent = String(textContent.prefix(maxDisplayLength))
                result = .success(content: truncatedContent, truncated: true)
            } else {
                result = .success(content: textContent, truncated: truncated)
            }
        }

        onEvent(.toolResult(toolUseId: toolUseId, result: result, durationMs: durationMs))
    }

    /// tool_result content can be a plain string or an array of content blocks
    private func extractTextContent(from content: Any?) -> String {
        if let str = content as? String {
            return str
        }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
        }
        return ""
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AgentActivity/ConversationLogWatcher.swift
git commit -m "feat(agent-activity): add ConversationLogWatcher

Incremental JSONL file watcher using DispatchSource EVFILT_VNODE.
Parses tool_use and tool_result content blocks from CC conversation
logs. Handles file-not-yet-created case by watching parent directory."
```

---

### Task 3: Event Store — AgentActivityStore.swift

**Files:**
- Create: `Sources/AgentActivity/AgentActivityStore.swift`

- [ ] **Step 1: Create AgentActivityStore with filter logic**

```swift
// Sources/AgentActivity/AgentActivityStore.swift
import Foundation
import Combine

/// Stores parsed ToolEvents for a single CC session and provides filtering.
final class AgentActivityStore: ObservableObject {

    @Published private(set) var events: [ToolEvent] = []
    @Published var selectedFilter: ToolType? = nil  // nil = All
    @Published private(set) var sessionEnded: Bool = false
    @Published private(set) var sessionEndedAt: Date? = nil

    /// Events filtered by the selected tool type
    var filteredEvents: [ToolEvent] {
        guard let filter = selectedFilter else { return events }
        return events.filter { $0.toolType == filter }
    }

    /// Count of events per tool type (for filter chip badges)
    var countsByType: [ToolType: Int] {
        var counts: [ToolType: Int] = [:]
        for event in events {
            counts[event.toolType, default: 0] += 1
        }
        return counts
    }

    func appendToolUse(_ event: ToolEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.events.append(event)
        }
    }

    func updateToolResult(toolUseId: String, result: ToolResult, durationMs: Int?) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let index = self.events.firstIndex(where: { $0.id == toolUseId }) else { return }
            self.events[index].result = result
            self.events[index].durationMs = durationMs
        }
    }

    func markSessionEnded() {
        DispatchQueue.main.async { [weak self] in
            self?.sessionEnded = true
            self?.sessionEndedAt = Date()
            // Mark any still-executing events as incomplete
            for i in self?.events.indices ?? 0..<0 {
                if self?.events[i].result == nil {
                    self?.events[i].result = .error(message: "Session ended before completion")
                }
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.events.removeAll()
            self?.sessionEnded = false
            self?.sessionEndedAt = nil
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AgentActivity/AgentActivityStore.swift
git commit -m "feat(agent-activity): add AgentActivityStore

Per-session event storage with @Published events, tool-type filtering,
count badges, and session-ended state management."
```

---

### Task 4: Session Tracker — AgentSessionTracker.swift

**Files:**
- Create: `Sources/AgentActivity/AgentSessionTracker.swift`

- [ ] **Step 1: Create AgentSessionTracker**

This is the top-level coordinator that maps panels to sessions and manages watcher lifecycles.

```swift
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
    @Published var manualOverride: Bool? = nil

    /// Computed sidebar visibility
    var sidebarVisible: Bool {
        manualOverride ?? hasActiveSessionOnFocusedPanel
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
            // Reset manual override when switching panels
            manualOverride = nil
        }

        updateFocusedStore()
    }

    func toggleSidebar() {
        if let current = manualOverride {
            manualOverride = !current
        } else {
            // First manual toggle: opposite of current auto state
            manualOverride = !hasActiveSessionOnFocusedPanel
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
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AgentActivity/AgentSessionTracker.swift
git commit -m "feat(agent-activity): add AgentSessionTracker

Coordinates panel-to-session mapping, ConversationLogWatcher lifecycle,
and focus tracking. Supports session switching (exit + restart CC in
same panel) and manual sidebar toggle override."
```

---

### Task 5: Shared Card Shell — ToolCardShell.swift

**Files:**
- Create: `Sources/AgentActivity/Cards/ToolCardShell.swift`

- [ ] **Step 1: Create ToolCardShell**

```swift
// Sources/AgentActivity/Cards/ToolCardShell.swift
import SwiftUI

/// Shared outer shell for all tool cards: left color bar, header with icon/timestamp, expand/collapse.
struct ToolCardShell<Content: View>: View {
    let event: ToolEvent
    @State private var isExpanded: Bool = false
    @State private var isHovering: Bool = false
    @ViewBuilder let content: (_ isExpanded: Bool) -> Content

    var body: some View {
        HStack(spacing: 0) {
            // Left color bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(colorForType(event.toolType))
                .frame(width: 3)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                // Header row: icon + tool name + summary + timestamp
                HStack(spacing: 6) {
                    if event.isExecuting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: event.toolType.sfSymbol)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                    }

                    Text(event.toolType.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let durationMs = event.durationMs {
                        Text(formatDuration(durationMs))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    Text(formatTimestamp(event.timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                // Card-specific content
                content(isExpanded)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color.primary.opacity(isHovering ? 0.08 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .onTapGesture { isExpanded.toggle() }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button(action: { copyToClipboard() }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
    }

    private func colorForType(_ type: ToolType) -> Color {
        switch type {
        case .bash: return .cyan
        case .read: return .blue
        case .write: return .green
        case .edit: return .yellow
        case .grep: return .purple
        case .glob: return .indigo
        case .agent: return .orange
        case .other: return .gray
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            let seconds = Double(ms) / 1000.0
            return String(format: "%.1fs", seconds)
        }
    }

    private func copyToClipboard() {
        let text = event.input.summary + "\n" + (event.result?.content ?? "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AgentActivity/Cards/ToolCardShell.swift
git commit -m "feat(agent-activity): add ToolCardShell

Shared card outer shell with left color bar, header (icon, tool name,
timestamp, duration), hover copy button, and expand/collapse toggle."
```

---

### Task 6: Tool-Specific Card Views

**Files:**
- Create: `Sources/AgentActivity/Cards/BashCardView.swift`
- Create: `Sources/AgentActivity/Cards/FileOpCardView.swift`
- Create: `Sources/AgentActivity/Cards/SearchCardView.swift`
- Create: `Sources/AgentActivity/Cards/AgentCardView.swift`

- [ ] **Step 1: Create BashCardView**

```swift
// Sources/AgentActivity/Cards/BashCardView.swift
import SwiftUI

struct BashCardView: View {
    let event: ToolEvent
    private let maxCollapsedLines = 10

    var body: some View {
        ToolCardShell(event: event) { isExpanded in
            VStack(alignment: .leading, spacing: 4) {
                // Command
                if case .bash(let command, _) = event.input {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                // Output
                if let result = event.result {
                    let text = result.content
                    let lines = text.components(separatedBy: "\n")
                    let shouldTruncate = !isExpanded && lines.count > maxCollapsedLines

                    let displayText = shouldTruncate
                        ? lines.prefix(maxCollapsedLines).joined(separator: "\n")
                        : text

                    if !displayText.isEmpty {
                        Text(displayText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(isExpanded ? nil : maxCollapsedLines)

                        if shouldTruncate {
                            Text("\(lines.count - maxCollapsedLines) more lines...")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if case .success(_, let truncated) = result, truncated {
                        Text(String(localized: "agentActivity.output.truncated",
                                    defaultValue: "Output truncated"))
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }

                    if result.isError {
                        Label(String(localized: "agentActivity.error",
                                     defaultValue: "Error"),
                              systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Create FileOpCardView (Read/Write/Edit)**

```swift
// Sources/AgentActivity/Cards/FileOpCardView.swift
import SwiftUI

struct FileOpCardView: View {
    let event: ToolEvent
    private let maxCollapsedLines = 5

    var body: some View {
        ToolCardShell(event: event) { isExpanded in
            VStack(alignment: .leading, spacing: 4) {
                // File path
                Text(event.input.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                // Edit-specific: show diff
                if case .edit(_, let oldString, let newString) = event.input {
                    VStack(alignment: .leading, spacing: 2) {
                        diffLine(prefix: "-", text: oldString, color: .red)
                        diffLine(prefix: "+", text: newString, color: .green)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                // Result content
                if let result = event.result {
                    let lines = result.content.components(separatedBy: "\n")
                    let shouldTruncate = !isExpanded && lines.count > maxCollapsedLines

                    if !result.content.isEmpty {
                        let displayText = shouldTruncate
                            ? lines.prefix(maxCollapsedLines).joined(separator: "\n")
                            : result.content

                        Text(displayText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(isExpanded ? nil : maxCollapsedLines)

                        if shouldTruncate {
                            Text("\(lines.count - maxCollapsedLines) more lines...")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func diffLine(prefix: String, text: String, color: Color) -> some View {
        let firstLine = text.components(separatedBy: "\n").first ?? text
        let display = firstLine.count > 80 ? String(firstLine.prefix(80)) + "..." : firstLine
        Text("\(prefix) \(display)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color.opacity(0.8))
    }
}
```

- [ ] **Step 3: Create SearchCardView (Grep/Glob)**

```swift
// Sources/AgentActivity/Cards/SearchCardView.swift
import SwiftUI

struct SearchCardView: View {
    let event: ToolEvent

    var body: some View {
        ToolCardShell(event: event) { isExpanded in
            VStack(alignment: .leading, spacing: 4) {
                // Pattern
                if case .grep(let pattern, let path, let glob) = event.input {
                    HStack(spacing: 4) {
                        Text(pattern)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary)
                        if let path {
                            Text("in \(path)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        if let glob {
                            Text("(\(glob))")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .textSelection(.enabled)
                } else if case .glob(let pattern, let path) = event.input {
                    HStack(spacing: 4) {
                        Text(pattern)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary)
                        if let path {
                            Text("in \(path)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                }

                // Results summary
                if let result = event.result {
                    let lines = result.content.components(separatedBy: "\n")
                        .filter { !$0.isEmpty }
                    if isExpanded {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("\(lines.count) results")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 4: Create AgentCardView**

```swift
// Sources/AgentActivity/Cards/AgentCardView.swift
import SwiftUI

struct AgentCardView: View {
    let event: ToolEvent

    var body: some View {
        ToolCardShell(event: event) { isExpanded in
            VStack(alignment: .leading, spacing: 4) {
                if case .agent(let description, let prompt) = event.input {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)

                    if isExpanded, let prompt, !prompt.isEmpty {
                        Text(prompt)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(20)
                    }
                }

                if let result = event.result {
                    Text(result.content.prefix(500))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 3)
                }
            }
        }
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentActivity/Cards/BashCardView.swift \
        Sources/AgentActivity/Cards/FileOpCardView.swift \
        Sources/AgentActivity/Cards/SearchCardView.swift \
        Sources/AgentActivity/Cards/AgentCardView.swift
git commit -m "feat(agent-activity): add tool-specific card views

BashCardView (command + output with truncation), FileOpCardView
(Read/Write/Edit with inline diff), SearchCardView (Grep/Glob with
result counts), AgentCardView (sub-agent description + prompt)."
```

---

### Task 7: Sidebar Container — AgentActivitySidebar.swift

**Files:**
- Create: `Sources/AgentActivity/AgentActivitySidebar.swift`

- [ ] **Step 1: Create AgentActivitySidebar**

```swift
// Sources/AgentActivity/AgentActivitySidebar.swift
import SwiftUI

struct AgentActivitySidebar: View {
    @ObservedObject var tracker: AgentSessionTracker

    var body: some View {
        Group {
            if let store = tracker.activeStore {
                ActiveSessionView(store: store)
            } else {
                EmptySessionView()
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Active Session View

private struct ActiveSessionView: View {
    @ObservedObject var store: AgentActivityStore
    @State private var autoScrollEnabled = true
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(String(localized: "agentActivity.title",
                            defaultValue: "Agent Activity"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.events.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Filter chips
            FilterChipsView(
                selectedFilter: $store.selectedFilter,
                counts: store.countsByType
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            Divider()

            // Event list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.filteredEvents) { event in
                            cardView(for: event)
                                .id(event.id)
                        }

                        if store.sessionEnded {
                            SessionEndedBanner(endedAt: store.sessionEndedAt)
                                .id("session-ended")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onAppear { scrollProxy = proxy }
                .onChange(of: store.events.count) { _ in
                    if autoScrollEnabled, let lastId = store.filteredEvents.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cardView(for event: ToolEvent) -> some View {
        switch event.toolType {
        case .bash:
            BashCardView(event: event)
        case .read, .write, .edit:
            FileOpCardView(event: event)
        case .grep, .glob:
            SearchCardView(event: event)
        case .agent:
            AgentCardView(event: event)
        case .other:
            // Fallback: use ToolCardShell with raw summary
            ToolCardShell(event: event) { _ in
                Text(event.input.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Filter Chips

private struct FilterChipsView: View {
    @Binding var selectedFilter: ToolType?
    let counts: [ToolType: Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                FilterChip(
                    label: String(localized: "agentActivity.filter.all",
                                  defaultValue: "All"),
                    count: counts.values.reduce(0, +),
                    isSelected: selectedFilter == nil,
                    action: { selectedFilter = nil }
                )

                ForEach(ToolType.allCases.filter { $0 != .other }) { type in
                    FilterChip(
                        label: type.rawValue,
                        count: counts[type] ?? 0,
                        isSelected: selectedFilter == type,
                        action: {
                            selectedFilter = selectedFilter == type ? nil : type
                        }
                    )
                }
            }
        }
    }
}

private struct FilterChip: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(isSelected ? .primary : .tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Empty & Ended States

private struct EmptySessionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(String(localized: "agentActivity.empty.title",
                        defaultValue: "No active agent session"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(localized: "agentActivity.empty.subtitle",
                        defaultValue: "Agent activity will appear here when Claude Code is running."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
    }
}

private struct SessionEndedBanner: View {
    let endedAt: Date?

    var body: some View {
        HStack {
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
            Text(String(localized: "agentActivity.sessionEnded",
                        defaultValue: "Session ended"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if let endedAt {
                Text(formatTime(endedAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
        }
        .padding(.vertical, 8)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AgentActivity/AgentActivitySidebar.swift
git commit -m "feat(agent-activity): add AgentActivitySidebar container

Sidebar view with header, horizontal filter chips (with count badges),
scrollable card list with auto-scroll, empty state, and session-ended
banner. Routes events to per-tool-type card views."
```

---

### Task 8: Socket Command Integration

**Files:**
- Modify: `CLI/cmux.swift` (session-start handler, ~line 12422)
- Modify: `Sources/TerminalController.swift` (add command handlers)
- Modify: `Sources/Workspace.swift` (add tracker property)

- [ ] **Step 1: Add `set_agent_session` socket command in CLI session-start handler**

In `CLI/cmux.swift`, after the existing `set_agent_pid` call in session-start (around line 12457-12462), add a new socket command to send session metadata to the app:

```swift
// CLI/cmux.swift — inside case "session-start", after the set_agent_pid block
// Add after line 12462 (after the closing brace of "if let claudePid {"):

if let sessionId = parsedInput.sessionId {
    let cwdArg = parsedInput.cwd.map { " --cwd=\($0)" } ?? ""
    _ = try? sendV1Command(
        "set_agent_session \(sessionId) --surface=\(surfaceId) --tab=\(workspaceId)\(cwdArg)",
        client: client
    )
}
```

In session-end (around line 12619-12621), add clear command before the existing clear commands:

```swift
// CLI/cmux.swift — inside case "session-end", before clearClaudeStatus
// Add before the existing "clear_status" line:

_ = try? sendV1Command("clear_agent_session --surface=\(surfaceId) --tab=\(workspaceId)", client: client)
```

- [ ] **Step 2: Add socket command handlers in TerminalController**

In `Sources/TerminalController.swift`, add handler registrations in `processCommand` (around line 1762-1766 where set_agent_pid/clear_agent_pid are):

```swift
// Add near set_agent_pid/clear_agent_pid handlers:
case "set_agent_session": return setAgentSession(args)
case "clear_agent_session": return clearAgentSession(args)
```

Add the handler methods (near the existing setAgentPID/clearAgentPID methods around line 14720):

```swift
private func setAgentSession(_ args: String) -> String {
    let parsed = parseOptions(args)
    guard let sessionId = parsed.positional.first else {
        return "ERROR: Usage: set_agent_session <sessionId> --surface=<id> --tab=<id> [--cwd=<path>]"
    }
    guard let surfaceId = parsed.options["surface"] else {
        return "ERROR: --surface required"
    }
    let cwd = parsed.options["cwd"] ?? ""

    let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
    guard let target = targetResolution.target else {
        return targetResolution.error ?? "ERROR: No tab selected"
    }
    scheduleSidebarMutation(target: target) { _, tab in
        tab.agentSessionTracker.registerSession(
            surfaceId: surfaceId,
            sessionId: sessionId,
            cwd: cwd
        )
    }
    return "OK"
}

private func clearAgentSession(_ args: String) -> String {
    let parsed = parseOptions(args)
    guard let surfaceId = parsed.options["surface"] else {
        return "ERROR: --surface required"
    }
    let targetResolution = parseSidebarMutationTabTarget(options: parsed.options)
    guard let target = targetResolution.target else {
        return targetResolution.error ?? "ERROR: No tab selected"
    }
    scheduleSidebarMutation(target: target) { _, tab in
        tab.agentSessionTracker.endSession(surfaceId: surfaceId)
    }
    return "OK"
}
```

- [ ] **Step 3: Add AgentSessionTracker to Workspace**

In `Sources/Workspace.swift`, add the tracker property near other published properties (around line 6614, near `agentPIDs`):

```swift
let agentSessionTracker = AgentSessionTracker()
```

- [ ] **Step 4: Commit**

```bash
git add CLI/cmux.swift Sources/TerminalController.swift Sources/Workspace.swift
git commit -m "feat(agent-activity): wire socket commands for session tracking

CLI session-start sends set_agent_session with sessionId, surfaceId,
cwd. Session-end sends clear_agent_session. TerminalController routes
to Workspace.agentSessionTracker. Workspace holds the tracker instance."
```

---

### Task 9: Sidebar Layout Integration in WorkspaceContentView

**Files:**
- Modify: `Sources/WorkspaceContentView.swift` (~line 380-388)

- [ ] **Step 1: Add sidebar to WorkspaceContentView layout**

In `Sources/WorkspaceContentView.swift`, the current layout ends with (around line 380-388):

```swift
Group {
    if isMinimalMode && !isFullScreen {
        bonsplitView.ignoresSafeArea(.container, edges: .top)
    } else {
        bonsplitView
    }
}
```

Replace with:

```swift
HStack(spacing: 0) {
    Group {
        if isMinimalMode && !isFullScreen {
            bonsplitView.ignoresSafeArea(.container, edges: .top)
        } else {
            bonsplitView
        }
    }

    if workspace.agentSessionTracker.sidebarVisible {
        Divider()
        AgentActivitySidebar(tracker: workspace.agentSessionTracker)
            .frame(width: 320)
    }
}
.animation(.easeInOut(duration: 0.2), value: workspace.agentSessionTracker.sidebarVisible)
```

- [ ] **Step 2: Add focus tracking**

The sidebar needs to know which panel is focused. In the same file, find where `workspace.focusPanel` is called or where focus changes are observed. Add an `onChange` handler to update the tracker's focused surface:

```swift
// Add as a modifier on the HStack:
.onChange(of: workspace.focusedPanelId) { newPanelId in
    workspace.agentSessionTracker.updateFocusedSurface(
        newPanelId.map { $0.uuidString }
    )
}
```

Note: The surfaceId in the hook system uses `CMUX_SURFACE_ID` which is the panel's UUID string. `workspace.focusedPanelId` is a `UUID?`. We convert with `.uuidString` to match.

- [ ] **Step 3: Commit**

```bash
git add Sources/WorkspaceContentView.swift
git commit -m "feat(agent-activity): integrate sidebar into workspace layout

HStack wraps BonsplitView + AgentActivitySidebar with animation.
Focus tracking updates the sidebar when the user switches panels."
```

---

### Task 10: Keyboard Shortcut Registration

**Files:**
- Modify: `Sources/KeyboardShortcutSettings.swift`

- [ ] **Step 1: Add toggleAgentSidebar action to KeyboardShortcutSettings.Action enum**

In `Sources/KeyboardShortcutSettings.swift`, add a new case to the `Action` enum (find the enum definition, add at the end before the closing brace):

```swift
case toggleAgentSidebar
```

Add label in the `label` computed property switch (around line 87-146):

```swift
case .toggleAgentSidebar: return "Toggle Agent Sidebar"
```

Add default shortcut in the `defaultShortcut` switch (around line 151-274):

```swift
case .toggleAgentSidebar:
    return StoredShortcut(key: "a", command: true, shift: true, option: false, control: false)
```

This assigns **Cmd+Shift+A** as the default shortcut for toggling the agent activity sidebar.

- [ ] **Step 2: Wire shortcut to toggle action**

In `Sources/WorkspaceContentView.swift`, add a keyboard shortcut handler near other shortcut registrations. Find where other shortcuts like `toggleSidebar` are wired and add:

```swift
// Find the pattern used for other shortcuts (likely .onCommand or .keyboardShortcut)
// and add for the agent sidebar toggle:
let agentSidebarShortcut = KeyboardShortcutSettings.shortcut(for: .toggleAgentSidebar)
// Wire to: workspace.agentSessionTracker.toggleSidebar()
```

The exact wiring depends on how other shortcuts are connected. Follow the existing pattern for `.toggleSidebar` or `.openBrowser`.

- [ ] **Step 3: Commit**

```bash
git add Sources/KeyboardShortcutSettings.swift Sources/WorkspaceContentView.swift
git commit -m "feat(agent-activity): register Cmd+Shift+A shortcut for sidebar toggle

Adds toggleAgentSidebar to KeyboardShortcutSettings.Action, wires
to AgentSessionTracker.toggleSidebar(). Visible in Settings, editable
in settings.json per CLAUDE.md shortcut policy."
```

---

### Task 11: pbxproj Registration + Build Verification

**Files:**
- Modify: `GhosttyTabs.xcodeproj/project.pbxproj`

- [ ] **Step 1: Register all new source files in pbxproj**

Add PBXFileReference, PBXBuildFile, and PBXGroup entries for:
1. `Sources/AgentActivity/ToolEvent.swift`
2. `Sources/AgentActivity/ConversationLogWatcher.swift`
3. `Sources/AgentActivity/AgentActivityStore.swift`
4. `Sources/AgentActivity/AgentSessionTracker.swift`
5. `Sources/AgentActivity/AgentActivitySidebar.swift`
6. `Sources/AgentActivity/Cards/ToolCardShell.swift`
7. `Sources/AgentActivity/Cards/BashCardView.swift`
8. `Sources/AgentActivity/Cards/FileOpCardView.swift`
9. `Sources/AgentActivity/Cards/SearchCardView.swift`
10. `Sources/AgentActivity/Cards/AgentCardView.swift`

Before choosing UUIDs, grep the pbxproj for unused UUID prefixes:

```bash
grep -o 'A[0-9A-F]\{3\}' GhosttyTabs.xcodeproj/project.pbxproj | sort -u
```

Pick a fresh prefix (e.g. `A600` series) that doesn't collide with existing entries.

- [ ] **Step 2: Build to verify everything compiles**

```bash
./scripts/reload.sh --tag agent-sidebar
```

Fix any compilation errors. Common issues:
- Missing imports (Foundation, SwiftUI, Combine)
- Type mismatches between TerminalController and Workspace
- Incorrect `parseOptions` usage (check existing patterns in TerminalController)

- [ ] **Step 3: Commit**

```bash
git add GhosttyTabs.xcodeproj/project.pbxproj
git commit -m "feat(agent-activity): register source files in pbxproj

Adds 10 new files under Sources/AgentActivity/ to the Xcode project.
BUILD SUCCEEDED with tag agent-sidebar."
```

---

### Task 12: Localization

**Files:**
- Modify: `Resources/Localizable.xcstrings`

- [ ] **Step 1: Add all new localized strings**

Add entries for all strings used in the sidebar views. The file is JSON format. Add these keys inside the `"strings"` object:

```json
"agentActivity.title": {
  "extractionState": "manual",
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Agent Activity" } },
    "ja": { "stringUnit": { "state": "translated", "value": "エージェント アクティビティ" } }
  }
},
"agentActivity.filter.all": {
  "extractionState": "manual",
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "All" } },
    "ja": { "stringUnit": { "state": "translated", "value": "すべて" } }
  }
},
"agentActivity.empty.title": {
  "extractionState": "manual",
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "No active agent session" } },
    "ja": { "stringUnit": { "state": "translated", "value": "アクティブなエージェントセッションなし" } }
  }
},
"agentActivity.empty.subtitle": {
  "extractionState": "manual",
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Agent activity will appear here when Claude Code is running." } },
    "ja": { "stringUnit": { "state": "translated", "value": "Claude Codeの実行中にエージェントのアクティビティがここに表示されます。" } }
  }
},
"agentActivity.sessionEnded": {
  "extractionState": "manual",
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Session ended" } },
    "ja": { "stringUnit": { "state": "translated", "value": "セッション終了" } }
  }
},
"agentActivity.output.truncated": {
  "extractionState": "manual",
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Output truncated" } },
    "ja": { "stringUnit": { "state": "translated", "value": "出力が切り捨てられました" } }
  }
},
"agentActivity.error": {
  "extractionState": "manual",
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Error" } },
    "ja": { "stringUnit": { "state": "translated", "value": "エラー" } }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add Resources/Localizable.xcstrings
git commit -m "feat(agent-activity): add localized strings (en + ja)

Sidebar title, filter labels, empty state, session ended, output
truncated, and error labels."
```

---

### Task 13: End-to-End Verification

- [ ] **Step 1: Build and launch**

```bash
./scripts/reload.sh --tag agent-sidebar --launch
```

- [ ] **Step 2: Manual smoke test**

1. Open a terminal panel in the tagged app
2. Run `claude` in the terminal
3. Verify sidebar auto-appears on the right
4. Give CC a task that uses multiple tools (e.g. "read the README and list all .swift files")
5. Verify cards appear in real-time as CC executes tools
6. Test filter chips: click Bash → only Bash cards shown, click again → back to All
7. Test Cmd+Shift+A → sidebar toggles off/on
8. Switch to a different terminal panel → sidebar follows (shows different session or empty state)
9. Exit CC → "Session ended" banner appears
10. Start CC again in the same panel → new session, fresh cards

- [ ] **Step 3: Commit any fixes from smoke testing**

```bash
git add -A
git commit -m "fix(agent-activity): fixes from end-to-end smoke testing"
```
