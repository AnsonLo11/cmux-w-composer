import Foundation
import SwiftUI

/// A single slash command entry with name and description.
struct SlashCommand: Equatable, Hashable {
    let name: String
    let description: String
    /// Source for deduplication priority: project > user > plugin > builtin.
    enum Source: Int, Comparable {
        case builtin = 0
        case plugin = 1
        case userCommand = 2
        case projectCommand = 3
        static func < (lhs: Source, rhs: Source) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    let source: Source
}

// MARK: - CompletionItem conformance

extension SlashCommand: CompletionItem {
    var detail: String { description }

    var tagStyle: CompletionTagStyle {
        switch source {
        case .builtin:
            return CompletionTagStyle(
                label: "Built-in",
                fg: Color(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0),
                bg: Color(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0).opacity(0.10)
            )
        case .plugin:
            return CompletionTagStyle(
                label: "Skill",
                fg: Color(red: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0),
                bg: Color(red: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0).opacity(0.12)
            )
        case .userCommand, .projectCommand:
            return CompletionTagStyle(
                label: "Custom",
                fg: Color(red: 0xA8 / 255.0, green: 0x55 / 255.0, blue: 0xF7 / 255.0),
                bg: Color(red: 0xA8 / 255.0, green: 0x55 / 255.0, blue: 0xF7 / 255.0).opacity(0.12)
            )
        }
    }
}

/// Discovers and caches slash commands from multiple sources:
/// 1. Built-in commands from Resources/slash-commands.json
/// 2. Plugin skills from ~/.claude/plugins/installed_plugins.json
/// 3. User custom commands from ~/.claude/commands/
/// 4. Project custom commands from .claude/commands/
final class SlashCommandRegistry {
    static let shared = SlashCommandRegistry()

    private let queue = DispatchQueue(label: "com.cmux.slash-command-registry", qos: .userInitiated)
    private var cachedCommands: [SlashCommand] = []
    private var lastLoadTime: Date?
    private let minReloadInterval: TimeInterval = 60

    /// All known commands, sorted alphabetically. Thread-safe read.
    var commands: [SlashCommand] {
        queue.sync { cachedCommands }
    }

    /// Returns commands whose name contains the given filter (case-insensitive).
    /// If filter is empty, returns all commands.
    func matching(_ filter: String) -> [SlashCommand] {
        let lower = filter.lowercased()
        let all = commands
        if lower.isEmpty { return all }
        return all.filter { $0.name.lowercased().contains(lower) }
    }

    /// Check if a command name is known.
    func isKnownCommand(_ name: String) -> Bool {
        let lower = name.lowercased()
        return commands.contains { $0.name.lowercased() == lower }
    }

    /// Reload commands if stale (> minReloadInterval since last load).
    /// Calls completion on main thread when done.
    func reloadIfNeeded(projectDirectory: String? = nil, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            if let last = self.lastLoadTime, Date().timeIntervalSince(last) < self.minReloadInterval {
                DispatchQueue.main.async { completion?() }
                return
            }
            self.performLoad(projectDirectory: projectDirectory)
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Force reload regardless of timing.
    func forceReload(projectDirectory: String? = nil, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            self?.performLoad(projectDirectory: projectDirectory)
            DispatchQueue.main.async { completion?() }
        }
    }

    // MARK: - Loading

    private func performLoad(projectDirectory: String?) {
        var all: [SlashCommand] = []
        all.append(contentsOf: loadBuiltinCommands())
        all.append(contentsOf: loadPluginSkills())
        all.append(contentsOf: loadCustomCommands(at: Self.userCommandsPath, source: .userCommand))
        if let projectDir = projectDirectory {
            let projectCommandsPath = (projectDir as NSString).appendingPathComponent(".claude/commands")
            all.append(contentsOf: loadCustomCommands(at: projectCommandsPath, source: .projectCommand))
        }
        // Deduplicate: higher-priority source wins
        var seen: [String: SlashCommand] = [:]
        for cmd in all {
            let key = cmd.name.lowercased()
            if let existing = seen[key] {
                if cmd.source > existing.source {
                    seen[key] = cmd
                }
            } else {
                seen[key] = cmd
            }
        }
        cachedCommands = seen.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lastLoadTime = Date()
    }

    // MARK: - Built-in commands

    private func loadBuiltinCommands() -> [SlashCommand] {
        guard let url = Bundle.main.url(forResource: "slash-commands", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([BuiltinEntry].self, from: data) else {
            return []
        }
        return entries.map {
            // Strip leading "/" if present (safety for copy-paste artifacts in JSON)
            let cleanName = $0.name.hasPrefix("/") ? String($0.name.dropFirst()) : $0.name
            return SlashCommand(name: cleanName, description: $0.description, source: .builtin)
        }
    }

    private struct BuiltinEntry: Decodable {
        let name: String
        let description: String
    }

    // MARK: - Plugin skills

    private static let installedPluginsPath: String = {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".claude/plugins/installed_plugins.json")
    }()

    private func loadPluginSkills() -> [SlashCommand] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.installedPluginsPath)),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
            return []
        }
        var results: [SlashCommand] = []
        for (pluginKey, installations) in manifest.plugins {
            // pluginKey format: "pluginName@marketplace"
            let pluginName = String(pluginKey.split(separator: "@").first ?? Substring(pluginKey))
            for installation in installations {
                let skillsDir = (installation.installPath as NSString).appendingPathComponent("skills")
                results.append(contentsOf: scanSkillDirectory(skillsDir, pluginName: pluginName))
            }
        }
        return results
    }

    private func scanSkillDirectory(_ path: String, pluginName: String) -> [SlashCommand] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        var results: [SlashCommand] = []
        for entry in entries {
            let entryPath = (path as NSString).appendingPathComponent(entry)
            let skillMD = (entryPath as NSString).appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: skillMD) {
                if let (name, desc) = parseSkillMD(at: skillMD) {
                    // Use short form if plugin == skill name
                    let commandName = (pluginName == name) ? name : "\(pluginName):\(name)"
                    results.append(SlashCommand(name: commandName, description: desc, source: .plugin))
                }
            } else {
                // Check for nested skills (e.g., notion/skills/notion/knowledge-capture/)
                results.append(contentsOf: scanSkillDirectory(entryPath, pluginName: pluginName))
            }
        }
        return results
    }

    private func parseSkillMD(at path: String) -> (name: String, description: String)? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        // Parse YAML frontmatter between --- delimiters
        let lines = content.components(separatedBy: .newlines)
        guard lines.first == "---" else { return nil }
        var name: String?
        var description: String?
        for line in lines.dropFirst() {
            if line == "---" { break }
            if line.hasPrefix("name:") {
                name = extractYAMLValue(line)
            } else if line.hasPrefix("description:") {
                description = extractYAMLValue(line)
            }
        }
        guard let n = name, !n.isEmpty else { return nil }
        return (n, description ?? "")
    }

    private func extractYAMLValue(_ line: String) -> String {
        let afterColon = line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
        // Remove surrounding quotes if present
        if afterColon.hasPrefix("\"") && afterColon.hasSuffix("\"") && afterColon.count >= 2 {
            return String(afterColon.dropFirst().dropLast())
        }
        return afterColon
    }

    private struct PluginManifest: Decodable {
        let version: Int
        let plugins: [String: [PluginInstallation]]
    }

    private struct PluginInstallation: Decodable {
        let installPath: String
    }

    // MARK: - Custom commands

    private static let userCommandsPath: String = {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".claude/commands")
    }()

    private func loadCustomCommands(at directory: String, source: SlashCommand.Source) -> [SlashCommand] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return entries.compactMap { entry -> SlashCommand? in
            guard entry.hasSuffix(".md") else { return nil }
            let name = String(entry.dropLast(3)) // Remove .md
            guard !name.isEmpty else { return nil }
            let filePath = (directory as NSString).appendingPathComponent(entry)
            let description = extractCommandDescription(at: filePath)
            return SlashCommand(name: name, description: description, source: source)
        }
    }

    /// Extract description from a custom command .md file:
    /// uses the first # heading, or the first non-empty line.
    private func extractCommandDescription(at path: String) -> String {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            return trimmed
        }
        return ""
    }
}
