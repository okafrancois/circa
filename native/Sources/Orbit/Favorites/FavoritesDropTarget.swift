import AppKit
import BrowserCore

/// Local drag interchange for SB-LIST. No URL, title or browsing content enters the pasteboard.
struct FavoritesDragPayload: Codable, Equatable {
    let profileID: ProfileID
    let nodes: [BrowserOrganizationNode]
    static let pasteboardType = NSPasteboard.PasteboardType("app.orbit.sidebar.organization-nodes")
}

/// A local SB-LIST dragging source may conform, or its shared coordinator may call the adapter
/// directly. External pasteboard strings/URLs never become trusted organization commands.
@MainActor
protocol FavoritesLocalDragSource: AnyObject {
    var favoritesDragPayload: FavoritesDragPayload? { get }
}

/// Small adapter, deliberately independent of SB-LIST's pending shared drop-target protocol.
/// Locations use grid-local flipped coordinates. The shared coordinator should reveal the empty
/// zone on entry, call update/perform, then end on leave, cancellation or session completion.
@MainActor
final class FavoritesDropTarget {
    weak var grid: FavoritesGridView?
    var onPreviewCountChange: ((Int?) -> Void)?
    var onEmptyZoneVisibilityChange: ((Bool) -> Void)?
    var validate: ((FavoritesDragPayload, BrowserOrganizationDestination) -> Bool)?
    var commit: ((FavoritesDragPayload, BrowserOrganizationDestination) -> Void)?
    var profileID: ProfileID?

    func begin() { onEmptyZoneVisibilityChange?(true) }
    @discardableResult
    func update(_ payload: FavoritesDragPayload, at point: NSPoint) -> Bool {
        guard let grid, let destination = destination(payload, at: point),
              validate?(payload, destination) == true else { end(); return false }
        begin()
        grid.showDropPreview(payload, at: point)
        onPreviewCountChange?(grid.previewItemCount)
        return true
    }
    @discardableResult
    func perform(_ payload: FavoritesDragPayload, at point: NSPoint) -> Bool {
        defer { end() }
        guard let destination = destination(payload, at: point), validate?(payload, destination) == true else { return false }
        commit?(payload, destination)
        return true
    }
    func end() {
        grid?.clearDropPreview()
        onPreviewCountChange?(nil)
        onEmptyZoneVisibilityChange?(false)
    }

    func destination(_ payload: FavoritesDragPayload, at point: NSPoint) -> BrowserOrganizationDestination? {
        guard let profileID, payload.profileID == profileID, !payload.nodes.isEmpty,
              payload.nodes.allSatisfy({ $0.tabID != nil }), Set(payload.nodes).count == payload.nodes.count,
              let grid else { return nil }
        let index = grid.insertionIndex(at: point)
        let anchor = grid.items.dropFirst(index).first { !payload.nodes.contains(.tab($0.tab.id)) }
        return BrowserOrganizationDestination(.favorites(profileID),
            position: anchor.map { .before(.tab($0.tab.id)) } ?? .end)
    }
}
