import Foundation
import BrowserCore

/// Window-owned, Space-local history. Cycling never mutates history until selection commits.
@MainActor
final class BrowserTabSwitcherModel {
    private var history: [SpaceID: [TabOccurrenceID]] = [:]
    private(set) var spaceID: SpaceID?
    private(set) var selectedID: TabOccurrenceID?
    private(set) var candidates: [TabOccurrenceID] = []
    private(set) var highlightedID: TabOccurrenceID?
    private(set) var isActive = false

    func reconcile(space: SpaceID, available: [TabOccurrenceID], selected: TabOccurrenceID?) {
        if spaceID != space || (isActive && selectedID != selected) { cancel() }
        spaceID = space
        let availableSet = Set(available)
        var order = history[space, default: []].filter { availableSet.contains($0) }
        let known = Set(order)
        order.append(contentsOf: available.filter { !known.contains($0) })
        if selectedID != selected || history[space] == nil {
            if let selected, availableSet.contains(selected) {
                order.removeAll { $0 == selected }
                order.insert(selected, at: 0)
            }
        }
        history[space] = order
        selectedID = selected
        if isActive {
            candidates.removeAll { !availableSet.contains($0) }
            if let highlightedID, !candidates.contains(highlightedID) { self.highlightedID = candidates.first }
            if candidates.isEmpty { cancel() }
        }
    }

    func cycle(backward: Bool = false) {
        if !isActive {
            guard let spaceID, let order = history[spaceID], order.count > 1 else { return }
            candidates = order
            highlightedID = selectedID ?? order.first
            isActive = true
        }
        guard let highlightedID, let index = candidates.firstIndex(of: highlightedID) else { return }
        self.highlightedID = candidates[(index + (backward ? candidates.count - 1 : 1)) % candidates.count]
    }

    func highlight(_ id: TabOccurrenceID) {
        if isActive && candidates.contains(id) { highlightedID = id }
    }

    func removeHighlighted() -> TabOccurrenceID? {
        guard isActive, let id = highlightedID, let index = candidates.firstIndex(of: id) else { return nil }
        candidates.remove(at: index)
        if let spaceID { history[spaceID]?.removeAll { $0 == id } }
        highlightedID = candidates.isEmpty ? nil : candidates[min(index, candidates.count - 1)]
        if candidates.isEmpty { cancel() }
        return id
    }

    func releaseControl() -> TabOccurrenceID? {
        guard isActive else { return nil }
        let result = highlightedID
        cancel()
        return result
    }

    func cancel() {
        isActive = false
        candidates = []
        highlightedID = nil
    }
}
