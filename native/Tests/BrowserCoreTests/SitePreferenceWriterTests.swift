import Foundation
import Testing
@testable import BrowserCore

@Suite("Site preference writer", .serialized)
@MainActor
struct SitePreferenceWriterTests {
    private func folder() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-site-writer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A burst of toggles updates memory at once and becomes one durable write")
    func coalescing() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preferences.json")
        let profile = ProfileID(), url = URL(string: "https://burst.example.test/")!
        let store = try BrowserSitePreferenceStore(destination: file)
        let writer = BrowserSitePreferenceWriter.shared(for: file)
        var value = store.preferences(url: url, profileID: profile)
        for index in 0..<20 {
            value.developerMode = index.isMultiple(of: 2)
            try store.set(value, url: url, profileID: profile)
            #expect(store.preferences(url: url, profileID: profile).developerMode == value.developerMode)
        }
        // Nothing reached the disk on the caller's thread.
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try await store.flushPendingWrites()
        #expect(writer.completedWrites == 1)
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect((decoded?["entries"] as? [Any])?.count == 1)
        #expect(try BrowserSitePreferenceStore(destination: file).preferences(url: url, profileID: profile) == value)
    }

    @Test("The coalescing timer writes without an explicit flush")
    func timerWrite() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preferences.json")
        let store = try BrowserSitePreferenceStore(destination: file)
        var value = BrowserSitePreferences()
        value.neverTranslate = true
        try store.set(value, url: URL(string: "https://timer.example.test/"), profileID: ProfileID())
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Reopening flushes the previous store; a quit flush and a profile clear are durable")
    func flushOnReopenQuitAndClear() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preferences.json")
        let profile = ProfileID(), url = URL(string: "https://quit.example.test/")!
        let store = try BrowserSitePreferenceStore(destination: file)
        var value = store.preferences(url: url, profileID: profile)
        value.blocksAdsAndTrackers = false
        try store.set(value, url: url, profileID: profile)
        #expect(try BrowserSitePreferenceStore(destination: file).contentBlockingExceptions(profileID: profile) == ["quit.example.test"])
        value.blocksAdsAndTrackers = true
        try store.set(value, url: url, profileID: profile)
        try store.flushPendingWritesNow()
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"blocksAdsAndTrackers\":true"))
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("backup").path))
        value.developerMode = true
        try store.set(value, url: url, profileID: profile)
        try store.clear(profileID: profile)
        let cleared = try String(contentsOf: file, encoding: .utf8)
        #expect(!cleared.contains("quit.example.test"))
    }

    @Test("Main-thread cost per toggle before and after (benchmark)",
          .enabled(if: ProcessInfo.processInfo.environment["ORBIT_SHELL_COST_BENCH"] != nil))
    func benchmark() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preferences.json")
        let profile = ProfileID(), url = URL(string: "https://bench.example.test/")!
        let store = try BrowserSitePreferenceStore(destination: file)
        var value = store.preferences(url: url, profileID: profile)
        try store.set(value, url: url, profileID: profile)
        try await store.flushPendingWrites()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try Data(contentsOf: file)
        func median(_ samples: [Duration]) -> Double {
            let sorted = samples.sorted()
            let mid = sorted[sorted.count / 2]
            return Double(mid.components.seconds) * 1000 + Double(mid.components.attoseconds) / 1e15
        }
        // Former path: backup copy then document, each with a full sync, on the caller.
        var before: [Duration] = []
        for _ in 0..<15 {
            let start = ContinuousClock.now
            if let previous = try BrowserPermissionFile.load(file) {
                try BrowserPermissionFile.save(previous, to: file.appendingPathExtension("backup"))
            }
            try BrowserPermissionFile.save(payload, to: file)
            before.append(start.duration(to: .now))
        }
        var after: [Duration] = []
        for index in 0..<15 {
            value.developerMode = index.isMultiple(of: 2)
            let start = ContinuousClock.now
            try store.set(value, url: url, profileID: profile)
            after.append(start.duration(to: .now))
        }
        try await store.flushPendingWrites()
        print(String(format: "SHELL-COST-BENCH site preference toggle on main: before %.2f ms, after %.4f ms (median of 15)",
                     median(before), median(after)))
    }
}
