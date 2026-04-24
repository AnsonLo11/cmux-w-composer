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
