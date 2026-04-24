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
