import AppKit
import BrowserShell
import Foundation
import Testing
import SwiftUI
@testable import Orbit

@Suite("Interface icon resources", .serialized)
@MainActor
struct OrbitIconTests {
    @Test("Rendered size selects the matching optical master, including export rounding")
    func opticalSizes() throws {
        for (pointSize, master): (CGFloat, Int) in [(10, 16), (17, 16), (18, 20), (20, 20), (21, 20), (22, 24), (48, 24)] {
            let url = try #require(OrbitIcon.resourceURL(sfName: "gearshape", pointSize: pointSize))
            #expect(url.path.contains("template/\(master)/gearshape.pdf"))
            let image = try #require(OrbitIcon.image(sfName: "gearshape", pointSize: pointSize))
            #expect(image.size == NSSize(width: pointSize, height: pointSize))
            #expect(image.isTemplate && image.representations.contains { $0 is NSPDFImageRep })
        }
    }

    @Test("Every shipped optical master and colour asset loads and rasterizes")
    func allAssetsLoad() throws {
        #expect(OrbitIcon.templateNames.count == 112)
        for name in OrbitIcon.templateNames {
            for size: CGFloat in [16, 20, 24] {
                let image = try #require(OrbitIcon.image(sfName: name, pointSize: size), "Missing \(name) at \(size)")
                #expect(image.representations.contains { $0 is NSPDFImageRep })
                #expect(image.isTemplate && image.tiffRepresentation != nil)
            }
        }
        #expect(Set(OrbitIcon.colorNames) == Set(BrowserSettingsSection.allCases.map(\.symbol)))
        for name in OrbitIcon.colorNames {
            let image = try #require(OrbitIcon.image(sfName: name, pointSize: 24, variant: .color))
            #expect(!image.isTemplate && image.tiffRepresentation != nil)
        }
    }

    @Test("Unknown brand names preserve the system fallback and accessibility description")
    func fallbackAndCopies() throws {
        let image = try #require(OrbitIcon.image(sfName: "heart", pointSize: 20, accessibilityDescription: "Test description"))
        #expect(image.symbolConfiguration != nil && image.accessibilityDescription == "Test description")
        #expect(OrbitIcon.resourceURL(sfName: "heart", pointSize: 20) == nil)
        #expect(OrbitIcon.image(sfName: "invalid.symbol.for.testing", pointSize: 16) == nil)
        let first = try #require(OrbitIcon.image(sfName: "globe", pointSize: 16, accessibilityDescription: "First"))
        first.size = NSSize(width: 30, height: 30)
        first.isTemplate = false
        let second = try #require(OrbitIcon.image(sfName: "globe", pointSize: 16))
        #expect(second.size == NSSize(width: 16, height: 16) && second.isTemplate)
        #expect(second.accessibilityDescription == nil)
    }

    @Test("User-selectable Space icons remain native symbols even when chrome has a matching asset")
    func spaceSymbols() throws {
        for name in ["globe", "lock.fill", "key.fill", "magnifyingglass", "bell.fill", "camera.fill", "location.fill"] {
            let space = try #require(SpaceIconImages.template(name, pointSize: 20))
            let chrome = try #require(OrbitIcon.image(sfName: name, pointSize: 20))
            #expect(!space.representations.contains { $0 is NSPDFImageRep } && chrome.representations.contains { $0 is NSPDFImageRep })
        }
    }

    @Test("All command and Settings symbol providers resolve to bundled masters")
    func dynamicProviders() {
        for command in BrowserCommandID.allCases {
            #expect(OrbitIcon.resourceURL(sfName: BrowserDailyCommands.symbol(command), pointSize: 16) != nil)
        }
        for section in BrowserSettingsSection.allCases {
            #expect(OrbitIcon.resourceURL(sfName: section.symbol, pointSize: 24, variant: .color) != nil)
        }
    }

    @Test("SwiftUI glyph swaps preserve font-driven layout beside text")
    func swiftUILayout() {
        for (name, size): (String, CGFloat) in [("person.crop.circle", 28), ("macwindow.on.rectangle", 38),
                                               ("ellipsis.circle", 13), ("arrow.turn.down.right", 28)] {
            let original = NSHostingView(rootView: HStack(spacing: 12) {
                Image(systemName: name).font(.system(size: size, weight: .light))
                Text("Layout sample")
            })
            let replacement = NSHostingView(rootView: HStack(spacing: 12) {
                OrbitIcon.view(sfName: name, pointSize: size).font(.system(size: size, weight: .light))
                Text("Layout sample")
            })
            #expect(original.fittingSize == replacement.fittingSize)
        }
    }

    @Test("Picker category fallbacks remain available as native interface symbols")
    func documentedFallbacks() throws {
        for name in ["box.truck", "face.smiling.inverse", "flag", "gift", "heart", "mug", "rosette", "sun.max"] {
            #expect(OrbitIcon.resourceURL(sfName: name, pointSize: 16) == nil)
            let image = try #require(OrbitIcon.image(sfName: name, pointSize: 16))
            #expect(!image.representations.contains { $0 is NSPDFImageRep })
        }
    }

    @Test("Interface constructors use the resolver; native constructors have explicit exclusions")
    func sourceCoverage() throws {
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = native.appendingPathComponent("Sources/Orbit")
        // Onboarding keeps its own reviewed artwork, like the empty-state and new-Space illustrations.
        let exclusions: Set<String> = ["SpaceIconImages.swift", "OrbitIcon.swift", "BrowserLibraryEmptyView.swift",
                                       "BrowserLibraryMediaView.swift", "SidebarNewSpacePageView.swift",
                                       "OrbitOnboardingControls.swift", "OrbitOnboardingSyncDiagram.swift"]
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Literal names cover the interface entry points; dynamic command and toolbar
            // providers are enumerated above. User-selected names have a separate renderer.
            let pattern = #"(?:sfName|symbol):\s*"([^"\\]+)"|OrbitGlyph\.symbol\("([^"\\]+)""#
            let names = try NSRegularExpression(pattern: pattern)
            for match in names.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let capture = match.range(at: 1).location == NSNotFound ? 2 : 1
                let range = try #require(Range(match.range(at: capture), in: source))
                let name = String(source[range])
                #expect(OrbitIcon.resourceURL(sfName: name, pointSize: 16) != nil,
                        "Unbundled interface literal in \(file.lastPathComponent): \(name)")
            }
            if source.contains("NSImage(systemSymbolName:") || source.contains("Image(systemName:") {
                #expect(exclusions.contains(file.lastPathComponent), "Unrouted icon constructor: \(file.lastPathComponent)")
            }
        }
    }
}
