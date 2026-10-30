import Foundation
import Testing
@testable import BrowserCore

struct OrbitUpdateWindowCheckpointTests {
    @Test("Update-only Little window checkpoints preserve profile, Space, document and placement")
    func roundTrip() throws {
        let root = URL(fileURLWithPath: "/private/tmp/update-windows-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("checkpoint.json")
        #expect(try OrbitUpdateWindowCheckpoint.load(from: file).isEmpty)
        let windows = [OrbitUpdateWindowCheckpoint(url: URL(string: "https://synthetic.test/document"),
            profileID: ProfileID(), spaceID: SpaceID(), frame: BrowserWindowPlacement(x: 12, y: 34, width: 700, height: 500, sidebarWidth: 164)),
            .init(url: nil, profileID: ProfileID(), spaceID: SpaceID(), frame: nil)]
        try OrbitUpdateWindowCheckpoint.save(windows, to: file)
        #expect(try OrbitUpdateWindowCheckpoint.load(from: file) == windows)
        try OrbitUpdateWindowCheckpoint.save([], to: file)
        #expect(try OrbitUpdateWindowCheckpoint.load(from: file).isEmpty)
    }
}
