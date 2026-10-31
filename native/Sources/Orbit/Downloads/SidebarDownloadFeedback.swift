import AppKit
import BrowserCore

/// A transient projection. The application coordinator remains the only download store.
@MainActor
final class SidebarDownloadFeedback {
    private(set) var items: [BrowserDownloadSnapshot] = []
    private(set) var completion: BrowserDownloadKey?
    private(set) var isHovering = false
    private var profile: ProfileID?
    var isPresented: Bool { isHovering && !items.isEmpty }
    var hasActiveDownloads: Bool { items.contains { !$0.state.isTerminal } }
    var completionItem: BrowserDownloadSnapshot? { items.first { $0.key == completion } }

    func update(_ snapshots: [BrowserDownloadSnapshot], profileID: ProfileID?) {
        let previous = profile == profileID ? Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0.state) }) : [:]
        if profile != profileID { completion = nil; isHovering = false }
        profile = profileID
        // Keep active transfers even when more than four recent files are available.
        let eligible = snapshots.filter { $0.owner.profileID == profileID }
        items = eligible
        if let finished = eligible.last(where: { $0.state == .complete && previous[$0.key]?.isTerminal == false }) {
            completion = isHovering ? nil : finished.key
        }
        if !items.contains(where: { $0.key == completion && $0.state == .complete }) { completion = nil }
        if items.isEmpty { isHovering = false }
    }

    var recentItems: [BrowserDownloadSnapshot] { Array(items.suffix(4)) }
    func hover(_ inside: Bool) { isHovering = inside; if inside { completion = nil } }
    func reset() { items = []; completion = nil; profile = nil; isHovering = false }
}

/// Sampled positions in points; interpolation does not add a new timing curve.
enum SidebarDownloadMotion {
    static let sampleTimes: [Double] = [0, 1.0/60, 2.0/60, 3.0/60, 4.0/60, 5.0/60, 6.0/60, 7.0/60, 8.0/60]
    static let entryOffsets: [Double] = [56, 28.5, 16.5, 11, 4, 1.5, 0.5, 0, 0]
    static let entryOpacity: [Double] = [0, 0.469, 0.680, 0.788, 0.919, 0.947, 0.970, 1, 1]
    static let exitOffsets: [Double] = [0, 11.5, 30, 39.5, 48.5, 49, 54.5, 56, 56]
    static let exitOpacity: [Double] = [1, 0.784, 0.455, 0.286, 0.128, 0.062, 0.025, 0, 0]
    static let stagger = 1.0/60
    static let exitStagger = 1.0/120
}
