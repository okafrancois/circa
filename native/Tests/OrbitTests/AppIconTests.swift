import AppKit
import BrowserShell
import Foundation
import Testing
@testable import Orbit

@Suite(.serialized)
@MainActor
struct AppIconTests {
    private func defaults() -> (UserDefaults, String) {
        let name = "lab.orbit.app-icons." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("Catalogue ships six selectable icons and a compatible legacy alias")
    func catalogue() throws {
        #expect(OrbitAppIcon.defaultIcon == .stage)
        #expect(OrbitAppIcon.allCases.map(\.id) == ["stage", "frost", "sunset", "riso", "afterglow", "ink"])
        #expect(OrbitAppIcon.stage.name == "Day")
        let directory = try #require(OrbitAppIcon.stage.iconURL).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(files) == Set((OrbitAppIcon.allCases + [.paper]).flatMap { [$0.id + ".icns", $0.id + ".png"] }))
        for icon in OrbitAppIcon.allCases {
            let image = try #require(icon.image)
            let sizes = Set(image.representations.map(\.pixelsWide))
            #expect(sizes.isSuperset(of: [16, 32, 64, 128, 256, 512, 1024]))
            #expect(icon.preview?.representations.first?.pixelsWide == 1024)
            #expect(!icon.name.isEmpty && !icon.description.isEmpty)
        }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shippedDefault = package.appendingPathComponent("OrbitChromium/App/Branding/Orbit.icns")
        #expect(try Data(contentsOf: shippedDefault) == Data(contentsOf: #require(OrbitAppIcon.stage.iconURL)))
    }

    @Test("Selection persists and reapplies to a replacement bundle on the next launch")
    func persistenceAndUpdate() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var dockCalls = 0, finderCalls = 0
        let first = OrbitAppIconController(defaults: defaults, setDockIcon: { _ in dockCalls += 1 }, setBundleIcon: { _ in finderCalls += 1; return true })
        #expect(first.current == .stage)
        #expect(first.apply(.paper))
        #expect(defaults.string(forKey: OrbitAppIconController.preferenceKey) == "paper")
        let relaunched = OrbitAppIconController(defaults: defaults, setDockIcon: { _ in dockCalls += 1 }, setBundleIcon: { image in
            finderCalls += 1; #expect(image != nil); return true
        })
        #expect(relaunched.current == .paper)
        relaunched.reapplyAtLaunch()
        #expect(dockCalls == 2 && finderCalls == 2 && relaunched.finderIconApplied == true)
    }

    @Test("Read-only bundle failures preserve the Dock choice and retry on launch; reset clears the custom icon")
    func restoreAndFailure() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var removed: [Bool] = [], dockCalls = 0
        let icons = OrbitAppIconController(defaults: defaults, setDockIcon: { _ in dockCalls += 1 }, setBundleIcon: { removed.append($0 == nil); return false })
        #expect(icons.apply(.ink))
        #expect(icons.current == .ink && icons.finderIconApplied == false)
        icons.reapplyAtLaunch()
        #expect(dockCalls == 2 && removed == [false, false])
        icons.restoreDefault()
        #expect(icons.current == .stage && defaults.object(forKey: OrbitAppIconController.preferenceKey) == nil)
        #expect(removed == [false, false, true] && dockCalls == 3)
        defaults.set("unknown-icon", forKey: OrbitAppIconController.preferenceKey)
        let recovered = OrbitAppIconController(defaults: defaults, setDockIcon: { _ in }, setBundleIcon: { _ in true })
        recovered.reapplyAtLaunch()
        #expect(recovered.current == .stage && defaults.object(forKey: OrbitAppIconController.preferenceKey) == nil)
    }

    @Test("Sheet rows include a radio, artwork, name, one-line description and current label; cancel preserves the applied choice")
    func sheetComposition() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var calls = 0
        let icons = OrbitAppIconController(defaults: defaults, setDockIcon: { _ in calls += 1 }, setBundleIcon: { _ in true })
        let sheet = BrowserSettingsAppIconSheet(icons: icons)
        defer { sheet.window?.close() }
        #expect(sheet.rows.count == 6 && !sheet.useButton.isEnabled && !sheet.restoreButton.isEnabled)
        for row in sheet.rows {
            #expect(row.radio.accessibilityLabel() == row.icon.name)
            #expect(row.artwork.image != nil && row.nameLabel.stringValue == row.icon.name)
            #expect(row.detailLabel.stringValue == row.icon.description && row.detailLabel.maximumNumberOfLines == 1)
            #expect(row.currentLabel.isHidden == (row.icon != .stage))
        }
        sheet.select(.riso)
        #expect(sheet.useButton.isEnabled && sheet.restoreButton.isEnabled)
        #expect(sheet.rows.filter { $0.radio.state == .on }.map(\.icon) == [.riso])
        sheet.cancelSheet()
        #expect(icons.current == .stage && calls == 0)
        sheet.useIcon()
        #expect(icons.current == .riso && calls == 1)
        let reopened = BrowserSettingsAppIconSheet(icons: icons)
        defer { reopened.window?.close() }
        #expect(reopened.rows.first { $0.icon == .riso }?.currentLabel.isHidden == false)
        reopened.restoreDefault()
        #expect(icons.current == .stage && calls == 2)
    }

    @Test("Every applied choice notifies the Dock tile plug-in after the preference is stored")
    func dockTileNotification() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var stored: [String?] = []
        let icons = OrbitAppIconController(defaults: defaults, setDockIcon: { _ in },
            notifyDockTile: { stored.append(defaults.string(forKey: OrbitAppIconController.preferenceKey)) },
            setBundleIcon: { _ in true })
        #expect(icons.apply(.ink))
        icons.reapplyAtLaunch()
        icons.restoreDefault()
        #expect(stored == ["ink", "ink", nil])
        #expect(OrbitAppIconController.changeNotificationName(applicationIdentifier: "lab.orbit.orbit.dock").rawValue
            == "lab.orbit.orbit.dock.applicationIconChanged")
    }

    @Test("The Dock tile plug-in reads the same key, notification and icon identifiers as the app")
    func dockTileContract() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resolver = try String(contentsOf: package.appendingPathComponent("OrbitChromium/DockTile/OrbitDockTileResolver.mm"), encoding: .utf8)
        #expect(resolver.contains("OrbitDockTilePreferenceKey = @\"\(OrbitAppIconController.preferenceKey)\";"))
        #expect(resolver.contains("OrbitDockTileChangeNotificationSuffix = @\"\(OrbitAppIconController.changeNotificationSuffix)\";"))
        // Every icon the app can store except the default, which the bundle's own icon shows.
        let custom = Set(OrbitAppIcon.allCases + [.paper]).subtracting([.defaultIcon]).map(\.rawValue)
        let line = try #require(resolver.split(separator: "\n").first { $0.contains("return @[") })
        let listed = line.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        #expect(Set(listed) == Set(custom) && listed.count == custom.count)
        for icon in listed { #expect(OrbitAppIcon(rawValue: icon)?.iconURL != nil) }
    }
}
