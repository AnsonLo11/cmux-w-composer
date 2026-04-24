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
        .background(Color(white: 0.08))
    }
}

// MARK: - Active Session View

private struct ActiveSessionView: View {
    @ObservedObject var store: AgentActivityStore
    @State private var autoScrollEnabled = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Text(String(localized: "agentActivity.title",
                            defaultValue: "Agent Activity"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(white: 0.85))
                Spacer()
                if store.events.count > 0 {
                    Text("\(store.events.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // Filter chips
            FilterChipsView(
                selectedFilter: $store.selectedFilter,
                counts: store.countsByType
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()
                .background(Color.white.opacity(0.08))

            // Event list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.filteredEvents) { event in
                            cardView(for: event)
                                .id(event.id)
                        }

                        if store.sessionEnded {
                            SessionEndedBanner(endedAt: store.sessionEndedAt)
                                .id("session-ended")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
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
            ToolCardShell(event: event) { _ in
                Text(event.input.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
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
            HStack(spacing: 5) {
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
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Color(white: 0.95) : Color(white: 0.5))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(isSelected ? Color(white: 0.8) : Color(white: 0.35))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
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
                .foregroundColor(Color(white: 0.25))
            Text(String(localized: "agentActivity.empty.title",
                        defaultValue: "No active agent session"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(white: 0.5))
            Text(String(localized: "agentActivity.empty.subtitle",
                        defaultValue: "Agent activity will appear here when Claude Code is running."))
                .font(.system(size: 11))
                .foregroundColor(Color(white: 0.35))
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
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            Text(String(localized: "agentActivity.sessionEnded",
                        defaultValue: "Session ended"))
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.35))
            if let endedAt {
                Text(formatTime(endedAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.35))
            }
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .padding(.vertical, 8)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}
