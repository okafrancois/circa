import Darwin
import Foundation
import Testing
@testable import BrowserCore

struct DiskWriteSettingsTests {
    @Test func repeatedActivityWritesOnce() async throws {
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let store = try BrowserSettingsStore(destination: file)
        let window = WindowID(), space = SpaceID()
        try await store.setLastActiveWindow(window, spaceID: space)
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        for _ in 0..<30 { try await store.setLastActiveWindow(window, spaceID: space) }
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber == inode)
        try await store.setLastActiveWindow(WindowID(), spaceID: space)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber != inode)
    }

    @Test func activityBarrierOmitsFullSync() throws {
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var barriers: [BrowserPermissionFile.WriteBarrier] = []
        try BrowserPermissionFile.save(Data("{}".utf8), to: root.appendingPathComponent("settings.json"),
                                       fullSync: false, barrier: { barriers.append($0) })
        #expect(barriers == [.written, .fileSynced, .replaced, .directorySynced])
    }
}
