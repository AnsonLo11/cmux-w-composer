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
                            .foregroundColor(Color(white: 0.8))
                        if let path {
                            Text("in \(path)")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.5))
                        }
                        if let glob {
                            Text("(\(glob))")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.4))
                        }
                    }
                    .textSelection(.enabled)
                } else if case .glob(let pattern, let path) = event.input {
                    HStack(spacing: 4) {
                        Text(pattern)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(white: 0.8))
                        if let path {
                            Text("in \(path)")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.5))
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
                                .foregroundColor(Color(white: 0.5))
                        }
                    } else {
                        Text("\(lines.count) results")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.5))
                    }
                }
            }
        }
    }
}
