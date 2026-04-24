// Sources/AgentActivity/Cards/BashCardView.swift
import SwiftUI

struct BashCardView: View {
    let event: ToolEvent
    private let maxCollapsedLines = 3
    @State private var outputExpanded: Bool = false

    var body: some View {
        ToolCardShell(event: event) { isExpanded in
            VStack(alignment: .leading, spacing: 6) {
                // Command with syntax highlighting (always visible)
                if case .bash(let command, _) = event.input {
                    BashHighlightedText(command: command)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Output section with its own expand/collapse
                if let result = event.result {
                    let effectiveExpanded = isExpanded || outputExpanded
                    outputView(result: result, isExpanded: effectiveExpanded)
                }
            }
        }
    }

    @ViewBuilder
    private func outputView(result: ToolResult, isExpanded: Bool) -> some View {
        // Error banner (always visible)
        if result.isError {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text(String(localized: "agentActivity.error", defaultValue: "Error"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.red)
        }

        let text = result.content
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        let hasMoreLines = lines.count > maxCollapsedLines

        if !text.isEmpty {
            if isExpanded {
                // Full output
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(white: result.isError ? 0.6 : 0.55))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if case .success(_, let truncated) = result, truncated {
                    Text(String(localized: "agentActivity.output.truncated",
                                defaultValue: "Output truncated"))
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }

                // Collapse button at the bottom of expanded output
                if hasMoreLines {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { outputExpanded = false } }) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 8, weight: .semibold))
                            Text(String(localized: "agentActivity.collapse",
                                        defaultValue: "Collapse"))
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(Color.cyan.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
                }
            } else {
                // Collapsed: show first few lines
                let previewLines = lines.prefix(maxCollapsedLines)
                let previewText = previewLines.joined(separator: "\n")

                Text(previewText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(white: result.isError ? 0.6 : 0.55))
                    .textSelection(.enabled)
                    .lineLimit(maxCollapsedLines)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // "N more lines..." as a clickable expand button
                if hasMoreLines {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { outputExpanded = true } }) {
                        Text("\(lines.count - maxCollapsedLines) more lines...")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.cyan.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Bash Syntax Highlighting

/// Simple regex-based tokenizer for bash command syntax highlighting.
private struct BashHighlightedText: View {
    let command: String

    var body: some View {
        Text(highlightedCommand)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .textSelection(.enabled)
    }

    private var highlightedCommand: AttributedString {
        var result = AttributedString(command)
        let baseColor = Color(white: 0.85)
        result.foregroundColor = baseColor

        let nsString = command as NSString

        // Strings (double-quoted and single-quoted)
        highlightPattern(
            &result, in: nsString,
            pattern: #"(?:"[^"]*"|'[^']*')"#,
            color: Color(red: 0.6, green: 0.8, blue: 0.5) // green
        )

        // Flags (--flag, -f)
        highlightPattern(
            &result, in: nsString,
            pattern: #"(?<=\s)--?[\w][\w-]*"#,
            color: Color(red: 0.55, green: 0.7, blue: 0.9) // light blue
        )

        // Pipes, redirects, semicolons, &&, ||
        highlightPattern(
            &result, in: nsString,
            pattern: #"[|&]{1,2}|[;<>]|>>|2>&1"#,
            color: Color(red: 0.85, green: 0.65, blue: 0.4) // orange
        )

        // Variables ($VAR, ${VAR})
        highlightPattern(
            &result, in: nsString,
            pattern: #"\$\{?\w+\}?"#,
            color: Color(red: 0.7, green: 0.6, blue: 0.9) // purple
        )

        // Command name (first word, or first word after | or ;)
        highlightPattern(
            &result, in: nsString,
            pattern: #"(?:^|(?<=\|\s?)|(?<=;\s?)|(?<=&&\s?))[\w./~-]+"#,
            color: Color(white: 0.95) // bright white
        )

        return result
    }

    private func highlightPattern(
        _ result: inout AttributedString,
        in nsString: NSString,
        pattern: String,
        color: Color
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = regex.matches(in: command, range: NSRange(location: 0, length: nsString.length))
        for match in matches {
            guard let range = Range(match.range, in: command),
                  let attrRange = Range(range, in: result) else { continue }
            result[attrRange].foregroundColor = color
        }
    }
}
