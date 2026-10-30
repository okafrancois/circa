import AppKit
import BrowserCore
import BrowserShell
import Foundation
import Testing
@testable import Orbit

@MainActor
struct TypeRevertTests {
    @Test("Display titles are confined to onboarding headings, Settings pane headings and About")
    func displayTitleScope() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Orbit")
        let allowed: [String: [String]] = [
            "Onboarding/OrbitOnboardingMetrics.swift": ["static func title(_ size: CGFloat)"],
            "Settings/BrowserSettingsAbout.swift": ["Text(ProductIdentity.displayName)"],
            "Settings/BrowserSettingsOrbitPanes.swift": ["Text((model.settingsSection ?? .general).title)",
                "Text(entry.name)", "Text(uiText(\"Little Orbit\"))"],
            "Settings/BrowserSettingsWindowController.swift": ["Text((model.settingsSection ?? .general).title)", "Text(space.name)"]
        ]
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var headings = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let path = String(file.path.dropFirst(sources.path.count + 1))
            for line in source.components(separatedBy: .newlines) where line.contains("BrandTextStyle.title") {
                #expect(allowed[path]?.contains(where: line.contains) == true, "Unexpected display title: \(path): \(line)")
                headings += 1
            }
            if source.contains("BrandFonts.onboardingBody") {
                #expect(path == "Onboarding/OrbitOnboardingMetrics.swift")
            }
            #expect(!source.contains("NSFont(name: \"Gloock"))
        }
        #expect(headings == 7)
    }

    @Test("Sidebar geometry and text metrics match the previous system-font rows")
    func sidebarGeometry() throws {
        let metrics = OrbitTokens.Metrics.Sidebar.self
        #expect(metrics.rowHeight == 36 && metrics.rowPitch == 41 && metrics.rowSpacing == 5)
        #expect(metrics.titleOriginX == 44 && metrics.rowInsetX == 10 && metrics.iconTitleGap == 10)
        #expect(OrbitTokens.Typography.sidebarTabTitle == NSFont.systemFont(ofSize: 14))
        #expect(OrbitTokens.Typography.sidebarFolderTitle == NSFont.systemFont(ofSize: 14, weight: .semibold))
        #expect(OrbitTokens.Typography.sidebarSpaceTitle == NSFont.systemFont(ofSize: 13, weight: .semibold))
        #expect(OrbitTokens.Typography.sidebarNewTab == NSFont.systemFont(ofSize: 14))
        let row = SidebarTabRow(item: .init(id: TabID(), title: "Synthetic tab with a long title", selected: false, favicon: nil))
        row.frame = NSRect(x: 0, y: 0, width: 228, height: 36)
        row.layoutSubtreeIfNeeded()
        #expect(row.titleLabel.font == NSFont.systemFont(ofSize: 14))
        #expect(row.titleLabel.frame.minX == 36)
        #expect(row.titleLabel.frame == NSRect(x: 36, y: 10, width: 182, height: 17))
        #expect(row.titleLabel.frame.height >= row.titleLabel.intrinsicContentSize.height)
        #expect(row.titleLabel.lineBreakMode == .byTruncatingTail)
        #expect(row.bounds.contains(row.titleLabel.frame))
        let history = BrowserLibraryHistoryView(frame: .zero)
        let historyFont = try #require(history.searchField.font)
        let nativeSearchFont = try #require(NSSearchField().font)
        #expect(historyFont.fontName == nativeSearchFont.fontName)
        #expect(historyFont.pointSize == nativeSearchFont.pointSize)
        #expect(historyFont.ascender == nativeSearchFont.ascender && historyFont.descender == nativeSearchFont.descender)
        let card = SidebarUpdateCard(frame: NSRect(x: 0, y: 0, width: 212, height: SidebarUpdateCard.height))
        card.layoutSubtreeIfNeeded()
        #expect(card.title.font == NSFont.systemFont(ofSize: 13, weight: .semibold))
        #expect(card.title.frame.height >= card.title.intrinsicContentSize.height)
    }
}
