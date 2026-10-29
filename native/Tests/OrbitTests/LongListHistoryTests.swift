import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Long history pagination", .serialized)
@MainActor
struct LongListHistoryTests {
    private func signature(_ rows: [BrowserLibraryHistoryView.Row]) -> [String] {
        rows.map {
            switch $0 {
            case let .day(day): return "day \(day.timeIntervalSinceReferenceDate)"
            case let .visit(visit): return visit.id.uuidString
            }
        }
    }

    @Test("Load More appends rows after the last day boundary; selection and the top visit stay exact")
    func appendPages() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-long-history-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: { BrowserEngineProfile(profileID: $0, persistence: .persistent) })
        let model = BrowserLibraryHistoryModel(); model.recorder = recorder
        defer { model.stop() }
        let profile = ProfileID()
        let base = Date(timeIntervalSinceReferenceDate: 812_462_400)
        let visits = (0..<1000).map { index in
            BrowserHistoryVisit(url: URL(string: "https://history.test/\(index)")!, title: "Synthetic \(index)",
                                visitedAt: base.addingTimeInterval(-Double(index) * 1800))
        }
        _ = try await recorder.importDocument(.init(profileID: profile, visits: visits))
        let view = BrowserLibraryHistoryView(frame: NSRect(x: 0, y: 0, width: 420, height: 720))
        model.onChange = { view.render(model, profileName: "Synthetic") }
        model.selectProfile(profile); await model.task?.value
        view.layoutSubtreeIfNeeded()
        #expect(model.visits.count == 200)
        let scroll = try #require(view.table.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 2600))
        scroll.reflectScrolledClipView(scroll.contentView)
        let selected = try #require(view.rows.indices.first { index in
            if case .visit = view.rows[index] { return index > 40 }; return false
        })
        view.table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        let selectedID = try #require(view.selectedVisit?.id)
        let origin = scroll.contentView.bounds.origin
        let top = view.table.row(at: NSPoint(x: 1, y: origin.y + 40))
        let reloads = view.reloadCount
        for page in 1...4 {
            let before = view.rows
            model.loadMore(); await model.task?.value
            #expect(model.visits.count == 200 * (page + 1))
            #expect(view.reloadCount == reloads && view.appendCount == page, "appending never reloads the table")
            #expect(Array(signature(view.rows).prefix(before.count)) == signature(before), "rows already shown keep their indices")
            #expect(view.table.numberOfRows == view.rows.count)
            #expect(view.selectedVisit?.id == selectedID)
            #expect(scroll.contentView.bounds.origin == origin)
            #expect(view.table.row(at: NSPoint(x: 1, y: origin.y + 40)) == top)
        }
        let rebuilt = BrowserLibraryHistoryView(frame: NSRect(x: 0, y: 0, width: 420, height: 720))
        rebuilt.render(model, profileName: "Synthetic")
        #expect(signature(view.rows) == signature(rebuilt.rows), "appended rows match a full rebuild, day headings included")
        let days = Set(model.visits.map { Calendar.current.startOfDay(for: $0.visitedAt) })
        #expect(view.rows.count == model.visits.count + days.count)
        model.search("Synthetic 1"); await model.task?.value
        #expect(view.reloadCount == reloads + 1, "a new query still rebuilds")
        try await recorder.close()
    }
}
}
