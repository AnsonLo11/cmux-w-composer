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
                    .foregroundColor(Color(white: 0.8))
                    .textSelection(.enabled)

                // Edit-specific: show diff
                if case .edit(_, let oldString, let newString) = event.input {
                    VStack(alignment: .leading, spacing: 2) {
                        diffLine(prefix: "-", text: oldString, color: .red)
                        diffLine(prefix: "+", text: newString, color: .green)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04))
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
                            .foregroundColor(Color(white: 0.5))
                            .textSelection(.enabled)
                            .lineLimit(isExpanded ? nil : maxCollapsedLines)

                        if shouldTruncate {
                            Text("\(lines.count - maxCollapsedLines) more lines...")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Color.cyan.opacity(0.6))
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
            .foregroundColor(color.opacity(0.7))
    }
}
