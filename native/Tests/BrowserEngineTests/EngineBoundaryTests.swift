import Foundation
import Testing

/// Keeps concrete engines behind the contract while many feature lots edit the shell in
/// parallel. A failure names the file that crossed the boundary.
@Suite("Engine boundary")
struct EngineBoundaryTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    private static func swiftFiles(in target: String) -> [URL] {
        let root = sources.appendingPathComponent(target)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    private static func violations(in target: String, forbidden: [String], allowed: Set<String> = []) throws -> [String] {
        try swiftFiles(in: target).compactMap { file in
            let relative = String(file.path.dropFirst(sources.path.count + 1))
            guard !allowed.contains(relative) else { return nil }
            let text = try String(contentsOf: file, encoding: .utf8)
            let hits = forbidden.filter { text.contains($0) }
            return hits.isEmpty ? nil : "\(relative): \(hits.joined(separator: ", "))"
        }
    }

    @Test("Engine-independent targets never import a web engine")
    func coreTargets() throws {
        for target in ["BrowserCore", "BrowserShell", "BrowserEngine", "BrowserEngineConformance"] {
            #expect(!Self.swiftFiles(in: target).isEmpty, "missing target \(target)")
            let found = try Self.violations(in: target, forbidden: ["import WebKit", "import WebKitEngine", "WKWebView", "cef_"])
            #expect(found.isEmpty, "\(found)")
        }
    }

    @Test("Orbit names a concrete engine only in its composition root")
    func shellTarget() throws {
        #expect(!Self.swiftFiles(in: "Orbit").isEmpty)
        let found = try Self.violations(
            in: "Orbit",
            forbidden: ["import WebKit", "import WebKitEngine", "WKWebView", "WKWebsiteDataStore", "WKDownload", ".webView", "WebKitSurface", "WebKitBrowserEngine"],
            allowed: ["Orbit/App/EngineComposition.swift"])
        #expect(found.isEmpty, "\(found)")
    }
}
