// Sources/AgentActivity/Cards/ToolCardShell.swift
import SwiftUI

private enum ToolCardTimestampFormatter {
    static let shared: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Shared outer shell for all tool cards: left color bar, header with icon/timestamp,
/// always-visible copy button, and a chevron to expand/collapse output.
struct ToolCardShell<Content: View>: View {
    let event: ToolEvent
    @State private var isExpanded: Bool = false
    @ViewBuilder let content: (_ isExpanded: Bool) -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left color bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(colorForType(event.toolType))
                .frame(width: 3)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 6) {
                // Header row: icon + tool name + timestamp + duration + copy
                HStack(spacing: 6) {
                    // Expand/collapse chevron
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color(white: 0.4))
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)

                    if event.isExecuting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: event.toolType.sfSymbol)
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.55))
                            .frame(width: 14, height: 14)
                    }

                    Text(event.toolType.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(white: 0.7))

                    Spacer()

                    Text(formatTimestamp(event.timestamp))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))

                    if let durationMs = event.durationMs {
                        Text(formatDuration(durationMs))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(white: 0.45))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    // Always-visible copy button
                    Button(action: { copyToClipboard() }) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.45))
                    }
                    .buttonStyle(.plain)
                }

                // Card-specific content
                content(isExpanded)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
        }
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        ToolCardTimestampFormatter.shared.string(from: date)
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
        let text = event.input.summary + (event.result.map { "\n" + $0.content } ?? "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
