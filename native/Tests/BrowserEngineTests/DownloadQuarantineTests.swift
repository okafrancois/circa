import BrowserEngine
import Darwin
import Foundation
import Testing

@Suite("Download quarantine preservation")
struct DownloadQuarantineTests {
    @Test("Main product and smoke templates opt into automatic file quarantine")
    func bundleTemplates() throws {
        let native = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for variant in ["App", "Smoke"] {
            let data = try Data(contentsOf: native.appendingPathComponent("OrbitChromium/\(variant)/Info.plist.in"))
            let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            #expect(info["LSFileQuarantineEnabled"] as? Bool == true)
        }
    }

    @Test("Finalization preserves quarantine, source metadata and bytes, including destination collisions",
          arguments: [false, true], [false, true])
    func stagingAttributes(collision: Bool, automatic: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-quarantine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("fixture.dmg")
        let selected = automatic ? try #require(BrowserDownloadPaths.uniqueDestination(filename: "fixture.dmg", in: root)) : target
        let staging = try BrowserDownloadStagingFile(destination: selected)
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: staging.file)
        let attributes = [
            "com.apple.quarantine": Data("0081;00000001;Orbit;00000000-0000-0000-0000-000000000001".utf8),
            "com.apple.metadata:kMDItemWhereFroms": try PropertyListSerialization.data(
                fromPropertyList: ["http://127.0.0.1/fixture.dmg", "http://127.0.0.1/"], format: .binary, options: 0)
        ]
        for (name, value) in attributes {
            let status = value.withUnsafeBytes { buffer in
                setxattr(staging.file.path, name, buffer.baseAddress, buffer.count, 0, 0)
            }
            #expect(status == 0)
        }
        if collision { try Data([9]).write(to: target) }
        let landed = try staging.finish()
        #expect(landed.lastPathComponent == (collision ? "fixture (1).dmg" : "fixture.dmg"))
        #expect(try Data(contentsOf: landed) == bytes)
        for (name, expected) in attributes {
            let size = getxattr(landed.path, name, nil, 0, 0, 0)
            #expect(size == expected.count)
            var actual = Data(count: max(0, size))
            let count = actual.withUnsafeMutableBytes { buffer in
                getxattr(landed.path, name, buffer.baseAddress, buffer.count, 0, 0)
            }
            #expect(count == expected.count)
            #expect(actual == expected)
        }
        if collision { #expect(try Data(contentsOf: target) == Data([9])) }
        #expect(!FileManager.default.fileExists(atPath: staging.file.deletingLastPathComponent().path))
    }
}
