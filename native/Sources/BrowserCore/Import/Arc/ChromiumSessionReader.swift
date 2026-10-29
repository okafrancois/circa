import Foundation

/// Bounded SNSS v1/v3 replay. Only navigation URLs/titles and structural commands are retained;
/// page state, POST bodies, geometry, tab groups and vendor-specific payloads are never restored.
enum ChromiumSessionReader {
    struct Tab: Equatable { let id: Int; let url: URL; let title: String; let pinned: Bool }
    struct Window: Equatable { let id: Int; let tabs: [Tab] }
    struct Result { let windows: [Window]; let capability: BrowserImportCapability }
    private struct State {
        var window: Int?; var index = 0; var selected = 0; var pinned = false
        var navigations: [Int: (URL, String)] = [:]
    }
    static func latest(in root: OrbitSecureDirectory) throws -> Result {
        if root.exists("Sessions_Encrypted") { return .init(windows: [], capability: .needsExport) }
        var candidates: [String] = []
        if root.exists("Sessions") {
            let folder = try root.directory("Sessions", create: false)
            candidates = folder.entries().compactMap { name -> (String, UInt64)? in
                guard name.hasPrefix("Session_"), let timestamp = UInt64(name.dropFirst(8)) else { return nil }
                return (name, timestamp)
            }.sorted { $0.1 > $1.1 }.map { "Sessions/" + $0.0 }
        }
        candidates += ["Current Session", "Last Session"].filter { root.exists($0) }
        var failure: BrowserImportCapability = .empty
        for name in candidates {
            let parts = name.split(separator: "/").map(String.init)
            let folder = parts.count == 1 ? root : try root.directory(parts[0], create: false)
            guard let data = folder.read(parts.last!, limit: Int(ArcSourceSnapshot.maximumDocumentBytes)) else { failure = .failed; continue }
            if data.count >= 8, Array(data.prefix(4)) == Array("SNSS".utf8), data[4] == 5 {
                return .init(windows: [], capability: .needsExport)
            }
            if let windows = try? read(data) { return .init(windows: windows, capability: .supported) }
            failure = .failed
        }
        // Tabs_* and Current/Last Tabs are recently closed history, never open-window state.
        return .init(windows: [], capability: failure)
    }
    static func read(_ data: Data) throws -> [Window] {
        var file = Cursor(data: Array(data))
        guard try file.take(4) == Array("SNSS".utf8) else { throw ArcImportError.unsupportedSourceFile }
        let version = try file.integer()
        guard version == 1 || version == 3 else { throw ArcImportError.unsupportedSourceFile }
        var marker = version == 1
        var tabs: [Int: State] = [:], types: [Int: Int] = [:]
        var closedWindows = Set<Int>()
        var commands = 0
        while file.offset < file.data.count {
            commands += 1
            guard commands <= 1_000_000 else { throw ArcImportError.unsupportedSourceFile }
            let size = try file.number(bytes: 2)
            guard size >= 1 else { throw ArcImportError.unreadableSourceDocument }
            let id = try file.number(bytes: 1)
            var payload = Cursor(data: try file.take(size - 1))
            if id == 255 { guard size == 1 else { throw ArcImportError.unreadableSourceDocument }; marker = true; continue }
            switch id {
            case 0:
                let window = try payload.integer(), tab = try payload.integer()
                tabs[tab, default: State()].window = window
            case 2, 7, 9:
                let key = try payload.integer(), value = try payload.integer()
                if id == 2 { tabs[key, default: State()].index = value }
                if id == 7 { tabs[key, default: State()].selected = value }
                if id == 9 { types[key] = value; closedWindows.remove(key) }
            case 6:
                let length = try payload.integer()
                guard length == payload.data.count - 4 else { throw ArcImportError.unreadableSourceDocument }
                let tab = try payload.integer(), index = try payload.integer()
                let text = try payload.string(), title = try payload.string(utf16: true)
                _ = try payload.string() // encoded page state, discarded
                _ = try payload.integer() // transition, history comes exclusively from History
                if let url = ChromiumBookmarkReader.safeURL(text) {
                    tabs[tab, default: State()].navigations[index] = (url, title)
                } else { tabs[tab, default: State()].navigations.removeValue(forKey: index) }
            case 12:
                let tab = try payload.integer(), pin = try payload.number(bytes: 1)
                guard pin <= 1 else { throw ArcImportError.unreadableSourceDocument }
                tabs[tab, default: State()].pinned = pin == 1
            case 3, 16: tabs.removeValue(forKey: try payload.integer())
            case 4, 17:
                let window = try payload.integer()
                closedWindows.insert(window)
                tabs = tabs.filter { $0.value.window != window }
            case 5, 11, 24:
                let tab = try payload.integer(), index = try payload.integer()
                var state = tabs[tab, default: State()]
                if id == 5 { state.navigations = state.navigations.filter { $0.key < index } }
                else {
                    let start = id == 11 ? 0 : index
                    let count = id == 11 ? index : try payload.integer()
                    guard start >= 0, count >= 0, start <= Int(Int32.max) - count else { throw ArcImportError.unreadableSourceDocument }
                    state.navigations = Dictionary(uniqueKeysWithValues: state.navigations.compactMap { key, value in
                        if key < start { return (key, value) }
                        if key >= start + count { return (key - count, value) }
                        return nil
                    })
                    if state.selected >= start { state.selected = max(start, state.selected - count) }
                }
                tabs[tab] = state
            default: break // unsupported commands do not become invented state
            }
        }
        guard marker else { throw ArcImportError.unreadableSourceDocument }
        let windows = Set(tabs.values.compactMap(\.window)).subtracting(closedWindows).sorted()
        return windows.compactMap { window in
            guard types[window] == 0 else { return nil } // normal browser windows only
            let values = tabs.filter { $0.value.window == window }.sorted {
                ($0.value.index, $0.key) < ($1.value.index, $1.key)
            }.compactMap { id, state -> Tab? in
                guard let navigation = state.navigations[state.selected] else { return nil }
                return Tab(id: id, url: navigation.0, title: navigation.1, pinned: state.pinned)
            }
            return values.isEmpty ? nil : Window(id: window, tabs: values)
        }
    }
    private struct Cursor {
        let data: [UInt8]
        var offset = 0
        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= data.count - offset else { throw ArcImportError.unreadableSourceDocument }
            defer { offset += count }
            return Array(data[offset..<offset + count])
        }
        mutating func number(bytes: Int) throws -> Int {
            try take(bytes).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        }
        mutating func integer() throws -> Int { Int(Int32(bitPattern: UInt32(try number(bytes: 4)))) }
        mutating func string(utf16: Bool = false) throws -> String {
            let length = try integer()
            guard length >= 0, length <= 65535 else { throw ArcImportError.unreadableSourceDocument }
            let bytes = try take(length * (utf16 ? 2 : 1))
            _ = try take((4 - bytes.count % 4) % 4)
            guard let value = String(data: Data(bytes), encoding: utf16 ? .utf16LittleEndian : .utf8) else {
                throw ArcImportError.unreadableSourceDocument
            }
            return value
        }
    }
}
