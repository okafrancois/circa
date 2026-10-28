import Foundation
import Testing

struct PublicHygieneTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("Tracked publication content satisfies the repository hygiene policy")
    func repositoryGuard() throws {
        try run("check-public-hygiene.py")
    }

    @Test("The hygiene policy rejects forbidden content and constrains its exceptions")
    func guardRegressionTests() throws {
        try run("test-public-hygiene.py")
    }

    private func run(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("scripts/" + script).path]
        process.currentDirectoryURL = root
        // A file avoids blocking on a full output pipe if a future audit finds many violations.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-hygiene-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(FileManager.default.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        let diagnostics = try String(contentsOf: output, encoding: .utf8)
        #expect(process.terminationStatus == 0, "\(script): \(diagnostics)")
    }
}
