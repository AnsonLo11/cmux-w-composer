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
