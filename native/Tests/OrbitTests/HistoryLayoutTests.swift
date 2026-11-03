import AppKit
import BrowserCore
import Testing
@testable import Orbit

@Suite("History layout") @MainActor
struct HistoryLayoutTests {
    @Test("Long titles keep a separate URL line and a readable timestamp", arguments: [CGFloat(232), CGFloat(372)])
    func independentFields(width: CGFloat) {
        let cell = BrowserHistoryVisitCell(frame: NSRect(x: 0, y: 0, width: width, height: 52))
        let visit = BrowserHistoryVisit(url: URL(string: "https://history.test/a/long/synthetic/path?value=123")!,
                                       title: String(repeating: "Synthetic title ", count: 20), visitedAt: Date())
        cell.render(visit, time: "23:45")
        cell.layoutSubtreeIfNeeded()
        #expect(cell.titleLabel.maximumNumberOfLines == 1)
        #expect(cell.urlLabel.maximumNumberOfLines == 1)
        #expect(cell.titleLabel.frame.maxX + 7 <= cell.timeLabel.frame.minX)
        #expect(cell.timeLabel.frame.width >= cell.timeLabel.intrinsicContentSize.width)
        #expect(cell.titleLabel.frame.height < 25)
        #expect(cell.urlLabel.frame.height < 20)
        #expect(cell.urlLabel.stringValue == visit.url.absoluteString)
        #expect(cell.toolTip?.contains(visit.title) == true)
        cell.render(.init(url: URL(string: "https://history.test/")!, title: "", visitedAt: Date()), time: "00:01")
        #expect(cell.titleLabel.stringValue == "history.test")
        #expect(cell.timeLabel.stringValue == "00:01")
    }

    @Test("History controls fit the narrow library panel", arguments: [CGFloat(280), CGFloat(420)])
    func controls(width: CGFloat) {
        let view = BrowserLibraryHistoryView(frame: NSRect(x: 0, y: 0, width: width, height: 720))
        view.layoutSubtreeIfNeeded()
        func controls(_ parent: NSView) -> [NSControl] {
            parent.subviews.flatMap { ($0 as? NSControl).map { [$0] } ?? controls($0) }
        }
        for control in controls(view) where control is NSButton || control is NSSearchField {
            let rect = control.convert(control.bounds, to: view)
            #expect(rect.minX >= 0 && rect.maxX <= width)
            #expect(rect.width > 16)
            if let button = control as? NSButton, button.imagePosition != .imageOnly {
                #expect(button.frame.width >= button.intrinsicContentSize.width - 1)
            }
        }
    }
}
