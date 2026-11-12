import Foundation
import Testing
@testable import BrowserShell
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

    private func catalog(_ language: String) throws -> [String: String] {
        let url = package.appendingPathComponent("Sources/BrowserShell/Resources/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let table = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        let source = try String(contentsOf: url, encoding: .utf8)
        let entries = try NSRegularExpression(pattern: #"(?m)^\s*"(?:[^"\\]|\\.)*"\s*="#)
        #expect(entries.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)) == table.count,
                "Duplicate keys in \(language)")
        return table
    }

    // Preserve argument positions and ABI types while allowing idiomatic word order.
    private func formatSignature(_ value: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"%(?:([0-9]+)\$)?([-+ #0]*[0-9]*(?:\.[0-9]+)?(?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSp]|%)"#)
        var next = 1
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { match in
            let spec = String(value[Range(match.range(at: 2), in: value)!])
            if spec == "%" { return "%%" }
            let position: String
            if let range = Range(match.range(at: 1), in: value) { position = String(value[range]) }
            else { position = String(next); next += 1 }
            return position + ":" + spec
        }.sorted()
    }

    @Test("French catalog is complete, unique and preserves format arguments and escapes")
    func frenchCatalog() throws {
        let english = try catalog("en"), french = try catalog("fr")
        #expect(Set(english.keys) == Set(french.keys))
        for (key, value) in french {
            let original = try #require(english[key])
            #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty translation: \(key)")
            #expect(try formatSignature(original) == formatSignature(value), "Format mismatch: \(key)")
            for escape in ["\n", "\t"] {
                #expect(original.filter { String($0) == escape }.count == value.filter { String($0) == escape }.count,
                        "Escaped whitespace mismatch: \(key)")
            }
        }
        // Names, symbols and words whose French spelling is identical are intentional.
        // Every other entry must contain a translation, not a copied English default.
        let invariant = Set([
            "%@\n%@\n→ %@", "%@ %@", "%@ %ld", "%@ · %@\n%@", "%ld%%",
            "%ld/%ld", "Aa", "Animations", "Circa", "Bing",
            "Bookmarks.html", "DuckDuckGo", "Extensions", "Format", "Google",
            "Grain", "Little Circa", "MIDI", "MIDI SysEx", "Microphone",
            "Notifications", "OK", "Option", "Pastel", "Services",
            "Substitutions", "Transformations", "Zoom", "Circa Live", "Chrome Web Store…",
            "Chrome Web Store", "Emoji", "Globe", "Art", "Photo",
            "Film", "Finance", "Terminal", "Code", "Puzzle",
            "Sport", "5 minutes", "15 minutes", "30 minutes", "example.org",
            "%@ · %@", "1 cookie", "%ld cookies", "Page", "%ld %%",
            "AA", "Boost", "Boosts", "CSS", "JS",
            "aa", "{}", "Options", "Cookies", "%@: %@",
            "%@ — %@", "%d s · %@", "iCloud", "Cobalt", "Mandarine", "Soleil", "Aurore", "Version %@ (%@)",
            "Riso", "⌘", "W", "URL", "Perplexity",
            "Chromium %@", "%@, %@", "Little Circa — %@", "example.com", "Codex",
            "Claude Code", "%ld min", "Max", "Ultra", "Assistant",
            "Suggestions", "Boost · %@", "GitHub",
        ])
        #expect(Set(french.filter { $0.key == $0.value }.keys) == invariant)
        #expect(french["Downloads"] == "Téléchargements")
        #expect(french["New Space…"] == "Nouvel espace…")
        #expect(french["Quit and Cancel Downloads"] == "Quitter et annuler les téléchargements")
    }

    @Test("French plural rules cover every English plural and preserve each branch's arguments")
    func frenchPluralCatalog() throws {
        func read(_ language: String) throws -> [String: [String: Any]] {
            let url = package.appendingPathComponent("Sources/BrowserShell/Resources/\(language).lproj/Localizable.stringsdict")
            return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: [String: Any]])
        }
        let english = try read("en"), french = try read("fr")
        #expect(Set(english.keys) == Set(french.keys))
        for (key, entry) in english {
            let translated = try #require(french[key])
            #expect(entry["NSStringLocalizedFormatKey"] as? String == translated["NSStringLocalizedFormatKey"] as? String)
            for (name, value) in entry where name != "NSStringLocalizedFormatKey" {
                let rule = try #require(value as? [String: String])
                let localized = try #require(translated[name] as? [String: String])
                #expect(Set(rule.keys) == Set(localized.keys))
                for (branch, text) in rule {
                    let actual = try #require(localized[branch])
                    if branch.hasPrefix("NSString") { #expect(actual == text) }
                    else {
                        #expect(!actual.isEmpty)
                        #expect(try formatSignature(text) == formatSignature(actual), "Plural format mismatch: \(key), \(branch)")
                    }
                }
            }
        }
    }

    /// A fresh Foundation process avoids Bundle's cached process language preferences.
    /// Compile the production lookup unchanged and exercise an adjacent packaged bundle.
    private func checkPreferredLanguages(in bundle: URL) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitFrenchLookup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let app = temporary.appendingPathComponent("LocaleProbe.app/Contents")
        let resources = app.appendingPathComponent("Resources")
        let binaries = app.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleExecutable": "lookup", "CFBundlePackageType": "APPL",
                                   "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en", "fr"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent("OrbitLabNative_BrowserShell.bundle"), withDestinationURL: bundle)
        let source = temporary.appendingPathComponent("main.swift")
        try #"""
        import Foundation
        let french = CommandLine.arguments[1] == "fr"
        func require(_ actual: String, _ expected: String) {
            if actual != expected { fputs("Expected \(expected), got \(actual)\n", stderr); exit(1) }
        }
        require(BrowserText.string("Downloads"), french ? "Téléchargements" : "Downloads")
        require(BrowserText.string("New Space…"), french ? "Nouvel espace…" : "New Space…")
        require(BrowserText.string("Unregistered fallback"), "Unregistered fallback")
        require(String(format: BrowserText.string("%@ of %@"), "12 MB", "20 MB"), french ? "12 MB sur 20 MB" : "12 MB of 20 MB")
        if french {
            for count in [0, 1, 2] {
                let word = count < 2 ? "mot de passe" : "mots de passe"
                require(String.localizedStringWithFormat(BrowserText.string("%ld passwords"), count), "\(count) \(word)")
                require(String.localizedStringWithFormat(BrowserText.string("%d passwords already in %@"), count, "Circa"), "\(count) \(word) déjà dans Circa")
            }
            require(String(format: BrowserText.string("Search %@ for “%@”"), "Google", "Circa"), "Rechercher « Circa » avec Google")
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        let executable = binaries.appendingPathComponent("lookup")
        func run(_ executable: URL, _ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        let result = try run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["swiftc", "-module-cache-path", temporary.appendingPathComponent("module-cache").path,
            package.appendingPathComponent("Sources/BrowserShell/BrowserText.swift").path, source.path, "-o", executable.path])
        try #require(result == 0)
        #expect(try run(executable, ["fr", "-AppleLanguages", "(fr-CA, fr, en)", "-AppleLocale", "fr_CA"]) == 0)
        #expect(try run(executable, ["en", "-AppleLanguages", "(en, fr)", "-AppleLocale", "en_US"]) == 0)
        #expect(try run(executable, ["en", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]) == 0)
    }

    @Test("SwiftPM resources select French regional preferences through production lookup")
    func swiftPMFrenchLookup() throws {
        let bundle = try #require(BrowserText.resourceBundle)
        #expect(Set(bundle.localizations) == Set(["en", "fr"]))
        try checkPreferredLanguages(in: bundle.bundleURL)
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
        for count in [1, 2] {
            let word = count == 1 ? "password" : "passwords"
            #expect(uiFormat("%d passwords not replaced (%@'s version kept)", count, ProductIdentity.displayName)
                == "\(count) \(word) not replaced (Circa's version kept)")
            #expect(uiFormat("%d passwords already in %@", count, ProductIdentity.displayName)
                == "\(count) \(word) already in Circa")
        }
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
        let pattern = #"(?:uiText|uiFormat|BrowserText\.string|\bsettingRow|\bliveToggle)\("([^"\n]+)"|(?:archiveText|libraryText|siteText|settingsText|\bstring|\btext)\("[^"\n]+", "([^"\n]*)""#
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

    @Test("CMake packages both languages and selects French without CEF or app execution",
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
        #expect(Set(bundle.localizations) == Set(["en", "fr"]))
        try checkPreferredLanguages(in: output)
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
