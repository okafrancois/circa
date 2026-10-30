import AppKit
import BrowserCore
import BrowserEngine

extension BrowserEnvironment {
    private var updateWindowCheckpoint: URL? { sessionFile?.appendingPathExtension("update-windows.json") }

    func checkpointQuickWindowsForUpdate() throws {
        guard let file = updateWindowCheckpoint else { return }
        let records = quickWindows.values.filter { !$0.isClosed }.map { window in
            OrbitUpdateWindowCheckpoint(url: window.opensWithDocument ? window.surface?.currentURL : nil, profileID: window.profileID,
                spaceID: window.sourceSpaceID, frame: window.window.map {
                    .init(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height, sidebarWidth: 164)
                })
        }
        try OrbitUpdateWindowCheckpoint.save(records, to: file)
    }

    func clearUpdateWindowCheckpoint() throws {
        guard let file = updateWindowCheckpoint else { return }
        try OrbitUpdateWindowCheckpoint.save([], to: file)
    }

    func restoreQuickWindowsAfterUpdate(present: (BrowserQuickWindowWindowController<Engine>) -> Void) async throws {
        guard let file = updateWindowCheckpoint else { return }
        var remaining = try OrbitUpdateWindowCheckpoint.load(from: file)
        while let record = remaining.first {
            let window = try await makeQuickWindow(spaceID: record.spaceID, url: record.url, preferredProfileID: record.profileID)
            if let frame = record.frame, [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite),
               frame.width >= 200, frame.height >= 100, frame.width <= 100_000, frame.height <= 100_000 {
                window.window?.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
            }
            do {
                try OrbitUpdateWindowCheckpoint.save(Array(remaining.dropFirst()), to: file)
            } catch {
                window.retire()
                window.window?.close()
                throw error
            }
            present(window)
            remaining.removeFirst()
        }
    }
}
