import Foundation
import Testing

struct ProductSourceSyntaxTests {
    @Test("Chromium application and smoke sources outside SwiftPM remain valid Swift")
    func chromiumApplicationSyntax() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("OrbitChromium")
        let files = ["App", "Smoke"].flatMap { directory -> [URL] in
            let entries = FileManager.default.enumerator(at: root.appendingPathComponent(directory),
                                                        includingPropertiesForKeys: nil)
            return (entries?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        }.sorted { $0.path < $1.path }
        #expect(!files.isEmpty)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-frontend", "-parse"] + files.map(\.path)
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(String(decoding: diagnostics, as: UTF8.self))")
    }
}
