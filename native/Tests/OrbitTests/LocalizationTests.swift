import Foundation
import Testing
import BrowserShell
import BrowserCore
@testable import Orbit

struct LocalizationTests {
    private var package: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("English resource keys occur exactly once after merging feature additions")
    func uniqueEnglishResourceKeys() throws {
        let file = package.appendingPathComponent("Sources/BrowserShell/Resources/en.lproj/Localizable.strings")
        let source = try String(contentsOf: file, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"(?m)^\s*("(?:[^"\\]|\\.)*")\s*="#)
        var keys: Set<String> = []
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let range = try #require(Range(match.range(at: 1), in: source))
            let key = try JSONDecoder().decode(String.self, from: Data(source[range].utf8))
            #expect(keys.insert(key).inserted, "Duplicate English resource key: \(key)")
        }
        #expect(keys.count > 600)
    }

    @Test("English defaults and formats are shared across feature helpers")
    func englishDefaults() {
        #expect(uiText("Downloads") == "Downloads")
        #expect(OrbitShellText.newSpace == "New Space…")
        #expect(SidebarListStrings.renameField == "Name")
        #expect(libraryText("history", "History") == "History")
        #expect(archiveText("title", "Archived Tabs") == "Archived Tabs")
        #expect(siteText("camera", "Camera") == "Camera")
        #expect(uiFormat("%@ of %@", "12 MB", "20 MB") == "12 MB of 20 MB")
        #expect(uiFormat("%ld results", 3) == "3 results")
        #expect(BrowserText.string("Unregistered English fallback") == "Unregistered English fallback")
        #expect(BrowserPaletteSection.tabs.localizedTitle == "Switch to Tab")
        #expect(SearchEngine.duckDuckGo.displayName == "DuckDuckGo")
    }

    @Test("English count phrases resolve stringsdict plural rules through uiText")
    func localizedPluralCounts() {
        for (key, singular, plural) in [
            ("%ld passwords", "1 password", "2 passwords"),
            ("%d passwords not replaced (Orbit's version kept)", "1 password not replaced (Orbit's version kept)", "2 passwords not replaced (Orbit's version kept)"),
            ("%ld cookies", "1 cookie", "2 cookies"),
            ("%ld Spaces", "1 Space", "2 Spaces"),
            ("%ld tabs and folders", "1 tab or folder", "2 tabs and folders"),
            ("%ld history visits", "1 history visit", "2 history visits"),
            ("%ld archived tabs", "1 archived tab", "2 archived tabs"),
            ("%ld existing passwords were kept.", "1 existing password was kept.", "2 existing passwords were kept."),
        ] {
            #expect(uiText(key, count: 1) == singular)
            #expect(uiText(key, count: 2) == plural)
        }
        #expect(uiText("%ld passwords", count: 0) == "0 passwords")
    }

    @Test("Key UI files do not introduce literal labels, tooltips, alerts or accessibility text")
    func noHardCodedUIStrings() throws {
        // Deliberately simple sink-based lint. Metadata-only literals (selectors, symbols,
        // accessibility IDs, logging and immutable Orbit menu observations) are not UI sinks.
        let sources = package.appendingPathComponent("Sources/Orbit")
        let excluded = Set(["OrbitCommandCatalog.swift", "OrbitMenuTree.swift", "BrowserFavoritesCommands.swift", "SidebarListCommands.swift", "BrowserSiteCommands.swift", "ArcImportCommands.swift", "BrowserBookmarkCommands.swift"])
        let pattern = #"(?:\b(?:labelWithString|wrappingLabelWithString|title|label|accessibilityDescription|withTitle):\s*|\.(?:toolTip|placeholderString|messageText|informativeText|stringValue|title)\s*=\s*|setAccessibility(?:Label|Help|Value)\(\s*)"([^"\n]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" && !excluded.contains(file.lastPathComponent) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (lineNumber, line) in source.components(separatedBy: .newlines).enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
                for match in matches {
                    let range = try #require(Range(match.range(at: 1), in: line))
                    let literal = String(line[range])
                    // Runtime page text and purely symbolic labels are not translation keys.
                    if literal.hasPrefix(#"\("#) || ["↩", "⌘T"].contains(literal) { continue }
                    Issue.record("Hard-coded UI text at \(file.lastPathComponent):\(lineNumber + 1): \(literal)")
                }
            }
        }
    }

    @Test("Every static localization default is in the English resource table")
    func resourceCoverage() throws {
        let resource = package.appendingPathComponent("Sources/BrowserShell/Resources/en.lproj/Localizable.strings")
        let data = try Data(contentsOf: resource)
        let table = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        #expect(table.count > 400)
        // Command definitions retain English keys; the shared registry performs
        // localization when a menu is built, just as for the other metadata files.
        for definition in BrowserBookmarkCommands.definitions {
            #expect(table[definition.title] == definition.title)
            #expect(definition.localizedTitle == uiText(definition.title))
        }
        let pattern = #"(?:uiText|uiFormat|BrowserText\.string)\("([^"\n]+)"|(?:archiveText|libraryText|siteText|settingsText|\bstring|\btext)\("[^"\n]+", "([^"\n]*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let files = try #require(FileManager.default.enumerator(at: package.appendingPathComponent("Sources"), includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" && (file.path.contains("/Orbit/") || file.path.contains("/BrowserShell/")) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let capture = match.range(at: 1).location == NSNotFound ? 2 : 1
                let range = try #require(Range(match.range(at: capture), in: source))
                let rawKey = String(source[range])
                let key = rawKey.replacingOccurrences(of: #"\n"#, with: "\n")
                guard !key.contains(#"\("#) else { continue }
                #expect(table[key] == key, "Missing English default in \(file.lastPathComponent): \(key)")
            }
        }
    }

    /// Strip lookup keys/defaults before checking remaining literals. Exact exceptions are
    /// limited to reviewed technical symbols, identifiers, delimiters and runtime data.
    private func remainingLiterals(in line: String) throws -> [String] {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return [] }
        let lookup = try NSRegularExpression(pattern: #"(?:uiText|uiFormat|BrowserText\.string)\("(?:[^"\\]|\\.)*"|(?:archiveText|libraryText|siteText|settingsText)\("(?:[^"\\]|\\.)*",\s*"(?:[^"\\]|\\.)*""#)
        let stripped = lookup.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "localized(")
        let literal = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
        return literal.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)).compactMap {
            Range($0.range, in: stripped).map { String(stripped[$0]) }
        }
    }

    @Test("Key feature files reject new literals regardless of the UI construction syntax")
    func reviewedLiteralAllowlist() throws {
        let path = package.appendingPathComponent("Tests/OrbitTests/Fixtures/localization-lint-exceptions.json")
        let exceptions = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: path))
        for (relativePath, allowed) in exceptions {
            let file = package.appendingPathComponent("Sources/Orbit/" + relativePath)
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                for literal in try remainingLiterals(in: line) {
                    #expect(allowed.contains(literal), "Unreviewed literal at \(relativePath):\(index + 1): \(literal)")
                }
            }
        }
        // These forms escaped the original sink-only lint. Each must now be detected.
        for sample in [#"NSTextField(string: "New Space")"#, #"detail = "Paused""#,
                       #"status = "Searching…""#, #"pair = ("xmark", "Cancel")"#,
                       #"title ?? "Favorite""#, #"states.append("Selected")"#,
                       #"addItems(withTitles: ["Downloads"])"#] {
            #expect(!(try remainingLiterals(in: sample)).isEmpty)
        }
        #expect(try remainingLiterals(in: #"detail = uiText("Paused")"#).isEmpty)
    }

    @Test("Dynamic menu and palette defaults remain covered by English resources")
    func dynamicResourceCoverage() throws {
        let path = package.appendingPathComponent("Sources/BrowserShell/Resources/en.lproj/Localizable.strings")
        let table = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? [String: String])
        func check(_ title: String) {
            if !title.isEmpty { #expect(table[title] == title, "Unregistered dynamic title: \(title)") }
        }
        func walk(_ nodes: [OrbitMenuNode]) {
            for node in nodes {
                switch node {
                case .item(let spec): check(spec.title)
                case .header(_, let title): check(title)
                case .submenu(let spec): check(spec.title); check(spec.menuTitle); walk(spec.children)
                case .separator: break
                }
            }
        }
        walk(OrbitMenuTree.bar)
        for definition in OrbitCommandCatalog.definitions { check(definition.title) }
        for section in BrowserPaletteSection.allCases { check(section.rawValue) }
    }

    private static var cmakeExecutable: String? {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return directories.map { $0 + "/cmake" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @Test("CMake produces an English resource bundle without CEF or app execution",
          .enabled(if: LocalizationTests.cmakeExecutable != nil, "Requires CMake for resource assembly"))
    func chromiumResourceAssembly() throws {
        let cmake = try #require(Self.cmakeExecutable)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitLocalization-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("OrbitLabNative_BrowserShell.bundle")
        func assemble(source: URL) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cmake)
            process.arguments = ["-DSOURCE=" + source.path, "-DDESTINATION=" + output.path, "-P", package.appendingPathComponent("OrbitChromium/PackageLocalization.cmake").path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try assemble(source: package.appendingPathComponent("Sources/BrowserShell/Resources")) == 0)
        let bundle = try #require(Bundle(url: output))
        #expect(bundle.developmentLocalization == "en")
        #expect(bundle.localizedString(forKey: "Downloads", value: "missing", table: nil) == "Downloads")
        let plural = bundle.localizedString(forKey: "%ld passwords", value: "missing", table: nil)
        #expect(String.localizedStringWithFormat(plural, 1) == "1 password")
        #expect(String.localizedStringWithFormat(plural, 2) == "2 passwords")
        #expect(try assemble(source: temporary.appendingPathComponent("missing")) != 0)
    }
    @Test("Product packager rejects missing resources before creating output on either input path")
    func packagingRejectsMissingResources() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitLocalizationPackaging-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", #"""
import importlib.util, pathlib, plistlib, sys
root, temporary = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(root / 'scripts'))
spec = importlib.util.spec_from_file_location('orbit_app', root / 'scripts/orbit-app.py')
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)
for use_source_app in (True, False):
    output = temporary / ('source.app.staged' if use_source_app else 'executable.app.staged')
    missing = temporary / 'missing'
    try:
        app.assemble(missing if use_source_app else None,
                     None if use_source_app else missing, missing, missing, output,
                     app.BUNDLE_ID, 'synthetic.20261025T161635Z')  # product mode: resources required
    except RuntimeError as error:
        assert 'localization resource bundle missing' in str(error), str(error)
    else:
        raise AssertionError('Missing localization was accepted')
    assert not output.exists(), 'Rejected packaging left partial output'
# Preserve the earlier explicit rejection of laboratory sources in product mode.
source = temporary / 'laboratory.app'
(source / 'Contents').mkdir(parents=True)
(source / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'lab.synthetic'}))
output = temporary / 'rejected-laboratory.app.staged'
try:
    app.assemble(source, None, None, None, output, app.BUNDLE_ID, 'synthetic.20261025T161635Z')
except RuntimeError as error:
    assert 'laboratory' in str(error), str(error)
else:
    raise AssertionError('Laboratory source was accepted for product packaging')
assert not output.exists(), 'Laboratory rejection left partial output'
"""#, package.deletingLastPathComponent().path, temporary.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
