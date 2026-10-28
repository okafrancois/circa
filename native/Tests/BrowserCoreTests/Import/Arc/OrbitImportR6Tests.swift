@testable import BrowserCore
import Darwin
import Foundation
import Testing

@Suite("source browser import R6 integrity", .serialized)
struct OrbitImportR6Tests {
    @Test("Indented v3 and v4 sessions are backed up and restored byte for byte", arguments: [3, 4])
    func exactSessionBytes(version: Int) async throws {
        let fixture = try OrbitImportTestFixture()
        defer { fixture.remove() }
        _ = try await fixture.seedExistingSession()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.sessionFile)) as? [String: Any])
        json["version"] = version
        if version == 3 { json.removeValue(forKey: "themeImports") }
        var original = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        original.append(contentsOf: [0x0a, 0x20, 0x09, 0x0a])
        try original.write(to: fixture.sessionFile)
        let decoded = try BrowserSessionDocument.decode(original)
        let target = try fixture.target()
        #expect(try await target.sessionBackup() == original)
        let importer = fixture.importer()
        let preparation = try await importer.prepare(for: target)
        let outcome = try await importer.apply(preparation, to: target)
        let persisted = try Data(contentsOf: fixture.sessionFile)
        #expect(persisted != original)
        #expect(try await target.sessionBackup() == persisted)
        await target.close()
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        let backupFile = location.backupsDirectory.appendingPathComponent(outcome.backupID).appendingPathComponent("session.json")
        #expect(try Data(contentsOf: backupFile) == original)
        try ArcImportBackups.restore(outcome.backupID, at: location, usage: NeverRunningProbe())
        #expect(try Data(contentsOf: fixture.sessionFile) == original)
        #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile) == decoded)
    }

    @Test("A reused target backs up the current persisted session", arguments: [false, true])
    func reusedTarget(existingSession: Bool) async throws {
        let fixture = try OrbitImportTestFixture()
        defer { fixture.remove() }
        if existingSession { _ = try await fixture.seedExistingSession() }
        let target = try fixture.target()
        let importer = fixture.importer()
        _ = try await importer.apply(try await importer.prepare(for: target), to: target)
        let current = try Data(contentsOf: fixture.sessionFile)
        let outcome = try await importer.apply(try await importer.prepare(for: target), to: target)
        await target.close()
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        #expect(try Data(contentsOf: location.backupsDirectory.appendingPathComponent(outcome.backupID)
            .appendingPathComponent("session.json")) == current)
        try ArcImportBackups.restore(outcome.backupID, at: location, usage: NeverRunningProbe())
        #expect(try Data(contentsOf: fixture.sessionFile) == current)
    }

    @Test("Twenty root and child inspection EIO failures retain zero opened descriptors", arguments: [false, true])
    func inspectionFailureClosesDescriptors(child: Bool) throws {
        let root = try OrbitFixture.temporaryDirectory("orbit-r6-descriptors")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try OrbitSecureDirectory.open(root, create: false)
        var retainedDescriptorCount = 0
        for _ in 0..<20 {
            var opened: Int32 = -1
            let failInspection: (Int32) throws -> OrbitSecureDirectory.Identity = { descriptor in
                opened = descriptor
                // Mark this open file description, so a concurrent suite reusing its closed
                // descriptor number cannot be mistaken for a leak.
                let flags = fcntl(descriptor, F_GETFL)
                #expect(flags >= 0)
                #expect(fcntl(descriptor, F_SETFL, flags | O_APPEND | O_NONBLOCK) == 0)
                errno = EIO
                throw POSIXError(.EIO)
            }
            #expect(throws: POSIXError.self) {
                if child {
                    _ = try directory.directory("child", create: true, inspect: failInspection)
                } else {
                    _ = try OrbitSecureDirectory.open(URL(fileURLWithPath: "/"), create: false, inspect: failInspection)
                }
            }
            #expect(opened >= 0)
            // Count only descriptors acquired by this operation; unrelated suites may open files.
            let flags = fcntl(opened, F_GETFL)
            if flags >= 0, flags & (O_APPEND | O_NONBLOCK) == (O_APPEND | O_NONBLOCK) {
                retainedDescriptorCount += 1
            }
        }
        #expect(retainedDescriptorCount == 0)
    }
}
