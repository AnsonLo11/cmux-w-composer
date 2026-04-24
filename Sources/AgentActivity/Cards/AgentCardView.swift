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
                        .foregroundColor(Color(white: 0.8))

                    if isExpanded, let prompt, !prompt.isEmpty {
                        Text(prompt)
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.5))
                            .lineLimit(20)
                    }
                }

                if let result = event.result {
                    Text(result.content.prefix(500))
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.5))
                        .lineLimit(isExpanded ? nil : 3)
                }
            }
        }
    }
}
