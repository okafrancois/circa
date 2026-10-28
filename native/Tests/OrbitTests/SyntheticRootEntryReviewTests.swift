import Foundation
import Testing
@testable import Orbit

/// Independent bounded root-entry review. Every location belongs to this disposable fixture.
@Suite("Synthetic root entry independent review", .serialized)
struct SyntheticRootEntryReviewTests {
    @Test("Root entries are checked before preparation writes", arguments: [
        "missing", "directory", "file", "directory-link", "file-link", "dangling-link"
    ])
    func rootEntryAdmission(kind: String) throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("orbit-root-review-" + UUID().uuidString)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let root = base.appendingPathComponent("root")
        let target = base.appendingPathComponent("owned-target")
        let support = base.appendingPathComponent("fake-home/Library/Application Support")
        // Parse while root is absent; replace its entry before calling real preparation.
        let configuration = try OrbitProductConfiguration(arguments: [
            "Orbit", "--use-mock-keychain", "--orbit-data-root=" + root.path
        ], applicationSupport: support, build: OrbitBuildIdentity(bundleIdentifier: nil, signature: nil))
        switch kind {
        case "directory":
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        case "file":
            try Data("synthetic-root-marker".utf8).write(to: root)
        case "directory-link":
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            try manager.createSymbolicLink(at: root, withDestinationURL: target)
        case "file-link":
            try Data("synthetic-target-marker".utf8).write(to: target)
            try manager.createSymbolicLink(at: root, withDestinationURL: target)
        case "dangling-link":
            try manager.createSymbolicLink(at: root, withDestinationURL: target)
        default: break
        }
        if kind == "missing" || kind == "directory" {
            try configuration.prepareDirectories()
            #expect(try manager.contentsOfDirectory(atPath: root.path) == ["Chromium"])
            let mode = try manager.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o700)
        } else {
            #expect(throws: (any Error).self) { try configuration.prepareDirectories() }
            #expect(!manager.fileExists(atPath: root.appendingPathComponent(".orbit-instance.lock").path))
            switch kind {
            case "directory-link":
                #expect(try manager.contentsOfDirectory(atPath: target.path).isEmpty)
                let mode = try manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
                #expect(mode?.intValue == 0o755)
            case "file-link":
                #expect(try Data(contentsOf: target) == Data("synthetic-target-marker".utf8))
            case "file":
                #expect(try Data(contentsOf: root) == Data("synthetic-root-marker".utf8))
            default:
                #expect(!manager.fileExists(atPath: target.path))
            }
        }
    }

    @Test("Personal-location refusal keeps precedence over a root link")
    func personalRefusalPrecedence() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("orbit-root-precedence-" + UUID().uuidString)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let target = base.appendingPathComponent("fake-personal")
        let root = base.appendingPathComponent("root")
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: root, withDestinationURL: target)
        let guardValue = SyntheticDataGuard(syntheticRoot: root, personalLocations: [target])
        #expect(throws: SyntheticDataGuard.Violation.personalLocation(root.standardizedFileURL.path)) {
            try guardValue.checkRoot()
        }
        #expect(try manager.contentsOfDirectory(atPath: target.path).isEmpty)
    }
}
