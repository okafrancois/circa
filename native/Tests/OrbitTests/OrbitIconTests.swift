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
            #expect(image.size == NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))?.size)
            #expect(image.isTemplate && image.representations.contains { $0 is NSCustomImageRep })
        }
    }

    @Test("Template ink matches the original symbol at sidebar and toolbar sizes and weights")
    func renderedInkParity() throws {
        for (name, size, weight): (String, CGFloat, NSFont.Weight) in [
            ("sidebar.left", 13, .medium), ("arrow.left", 12, .medium),
            ("arrow.clockwise", 14, .medium), ("plus", 13, .medium),
            ("ellipsis", 12, .bold), ("xmark", 10, .semibold),
            ("globe", 20, .regular), ("gearshape", 24, .regular), ("plus", 20, .regular),
            ("plus", 20, .bold), ("plus", 20, .regular)
        ] {
            let original = try #require(NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: weight)))
            let replacement = try #require(OrbitIcon.image(sfName: name, pointSize: size, weight: weight))
            let expected = try #require(OrbitIcon.inkBounds(of: original))
            let actual = try #require(OrbitIcon.inkBounds(of: replacement))
            #expect(replacement.size == original.size)
            #expect(replacement.alignmentRect == original.alignmentRect)
            #expect(abs(actual.width - expected.width) <= 0.5, "Width: \(name), \(weight)")
            #expect(abs(actual.height - expected.height) <= 0.5, "Height: \(name), \(weight)")
            #expect(abs(actual.minX - expected.minX) <= 0.5)
            #expect(abs(actual.minY - expected.minY) <= 0.5)
        }
        for name in OrbitIcon.colorNames {
            #expect(OrbitIcon.image(sfName: name, pointSize: 24, variant: .color)?.size == NSSize(width: 24, height: 24))
        }
    }

    @Test("URL accessories retain template ink and resolve it at their final symbol size")
    func accessorySizing() throws {
        let pill = SidebarAddressField(frame: NSRect(x: 0, y: 0, width: 312, height: 36))
        let button = SiteControlButton("", identifier: "share-page", onPress: {})
        button.image = try #require(OrbitIcon.image(sfName: "square.and.arrow.up", pointSize: 16))
        pill.installAccessory(button)
        let actual = try #require(button.image)
        let expected = try #require(OrbitIcon.image(sfName: "square.and.arrow.up", pointSize: 14))
        #expect(actual.size == expected.size)
        #expect(OrbitIcon.inkBounds(of: actual) == OrbitIcon.inkBounds(of: expected))
        #expect(actual.isTemplate)
    }

    @Test("Every shipped optical master and colour asset loads and rasterizes")
    func allAssetsLoad() throws {
        #expect(OrbitIcon.templateNames.count == 113)
        for name in OrbitIcon.templateNames {
            for size: CGFloat in [16, 20, 24] {
                let image = try #require(OrbitIcon.image(sfName: name, pointSize: size), "Missing \(name) at \(size)")
                #expect(image.representations.contains { $0 is NSCustomImageRep })
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
        #expect(second.size == NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular))?.size && second.isTemplate)
        #expect(second.accessibilityDescription == nil)
    }

    @Test("User-selectable Space icons remain native symbols even when chrome has a matching asset")
    func spaceSymbols() throws {
        for name in ["globe", "lock.fill", "key.fill", "magnifyingglass", "bell.fill", "camera.fill", "location.fill"] {
            let space = try #require(SpaceIconImages.template(name, pointSize: 20))
            let chrome = try #require(OrbitIcon.image(sfName: name, pointSize: 20))
            #expect(!space.representations.contains { $0 is NSCustomImageRep } && chrome.representations.contains { $0 is NSCustomImageRep })
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
            #expect(!image.representations.contains { $0 is NSCustomImageRep })
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
