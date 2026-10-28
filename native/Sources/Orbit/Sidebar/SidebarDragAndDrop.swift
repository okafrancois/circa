import AppKit
import BrowserCore

/// Rows dragged from a sidebar region (the list here, the Favorites grid of the FAVORITES lot),
/// as published on the drag pasteboard. Process-local identities only: no address, title or other
/// browsing content is written, and other applications see no drag type they understand.
struct SidebarDragPayload: Codable, Equatable {
    /// `BrowserWindowController.id` of the window the drag started in.
    let sourceWindow: UUID
    let spaceID: SpaceID
    let profileID: ProfileID
    /// Top-level dragged nodes in display order; a folder's children move with it.
    let nodes: [BrowserOrganizationNode]
    /// Visible rows the drag lifts out of its list (a folder counts its visible children): the
    /// placeholder opened under the pointer has as many pitches.
    let rowCount: Int
    /// Pointer x minus the dragged row's icon x, so the insertion depth follows the icon.
    let grabOffsetX: CGFloat

    static let pasteboardType = NSPasteboard.PasteboardType("org.orbit.sidebar-rows")

    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(self) { item.setData(data, forType: Self.pasteboardType) }
        return item
    }

    init(sourceWindow: UUID, spaceID: SpaceID, profileID: ProfileID, nodes: [BrowserOrganizationNode],
         rowCount: Int, grabOffsetX: CGFloat) {
        self.sourceWindow = sourceWindow
        self.spaceID = spaceID
        self.profileID = profileID
        self.nodes = nodes
        self.rowCount = rowCount
        self.grabOffsetX = grabOffsetX
    }

    init?(pasteboard: NSPasteboard) {
        guard let data = pasteboard.pasteboardItems?.first?.data(forType: Self.pasteboardType),
              let payload = try? JSONDecoder().decode(SidebarDragPayload.self, from: data),
              !payload.nodes.isEmpty else { return nil }
        self = payload
    }
}

/// A sidebar region that accepts dragged rows (ORBIT-DRAG). `BrowserSidebarView` is the single
/// AppKit dragging destination: it asks the frontmost target under the pointer for a proposal,
/// validates it against the window's organization snapshot (`validateMove`), shows the verdict
/// through the target and commits with the session. Targets only map points to destinations and
/// draw feedback, so every region shares validation, invalid-drop feedback and cross-window
/// commits. The list implements it for Pinned/Today; the FAVORITES lot implements it for the grid
/// and registers it with `BrowserSidebarView.addDropTarget(_:)`.
@MainActor
protocol SidebarDropTarget: AnyObject {
    /// The view whose coordinates proposals use.
    var dropTargetView: NSView { get }
    /// Whether the pointer (in `container` coordinates) is over this region. Defaults to the
    /// visible bounds of `dropTargetView`; an empty Favorites grid answers for its potential zone.
    func acceptsDrag(at point: NSPoint, in container: NSView) -> Bool
    /// - point: pointer in `dropTargetView` coordinates.
    func dropProposal(for payload: SidebarDragPayload, at point: NSPoint,
                      in snapshot: BrowserOrganizationSnapshot) -> SidebarDropProposal?
    /// Shows the current proposal, accepted or refused; nil clears the feedback.
    func showDropFeedback(_ proposal: SidebarDropProposal?, isValid: Bool, payload: SidebarDragPayload?)
    /// Where the drag image settles for an accepted drop, in `dropTargetView` coordinates.
    func dropFrame(for proposal: SidebarDropProposal) -> NSRect?
    /// The sidebar accepted a drop on this target (`changesOrganization` is false for rows
    /// dropped back in place). Return true when the target committed the move itself; otherwise
    /// the sidebar commits it and the target keeps its feedback until the update arrives.
    func didAcceptDrop(_ proposal: SidebarDropProposal, payload: SidebarDragPayload, changesOrganization: Bool) -> Bool
    /// A drag started or ended anywhere in this window's sidebar (e.g. to open an empty
    /// Favorites drop zone while rows are dragged). Nil when it ended.
    func sidebarDragDidChange(_ payload: SidebarDragPayload?)
}

extension SidebarDropTarget {
    func acceptsDrag(at point: NSPoint, in container: NSView) -> Bool {
        let view = dropTargetView
        guard !view.isHiddenOrHasHiddenAncestor, view.window != nil else { return false }
        // `visibleRect` can extend past the bounds of views that do not clip (macOS 14+).
        return view.bounds.intersection(view.visibleRect).contains(view.convert(point, from: container))
    }
    func dropFrame(for proposal: SidebarDropProposal) -> NSRect? { nil }
    func didAcceptDrop(_ proposal: SidebarDropProposal, payload: SidebarDragPayload, changesOrganization: Bool) -> Bool {
        showDropFeedback(nil, isValid: false, payload: nil)
        return false
    }
    func sidebarDragDidChange(_ payload: SidebarDragPayload?) {}
}

/// Validation and routing state of the drag currently over one sidebar. Separate from the view so
/// the rules (frontmost target, synchronous validation, refused feedback) are testable.
@MainActor
final class SidebarDropCoordinator {
    struct Verdict: Equatable {
        let proposal: SidebarDropProposal
        let error: BrowserOrganizationError?
        var isValid: Bool { error == nil }
    }

    private(set) var payload: SidebarDragPayload?
    private(set) var verdict: Verdict?
    private weak var target: (any SidebarDropTarget)?

    var currentTarget: (any SidebarDropTarget)? { target }

    /// Re-evaluates the drag at `point` (in `container` coordinates). Returns the verdict shown.
    @discardableResult
    func update(payload: SidebarDragPayload, at point: NSPoint, in container: NSView,
                targets: [any SidebarDropTarget], snapshot: BrowserOrganizationSnapshot?,
                catalog: BrowserCatalogSnapshot?) -> Verdict? {
        self.payload = payload
        let hit = targets.first { $0.acceptsDrag(at: point, in: container) }
        if hit !== target {
            target?.showDropFeedback(nil, isValid: false, payload: nil)
            target = hit
        }
        guard let hit, let snapshot, let catalog else {
            verdict = nil
            return nil
        }
        let local = hit.dropTargetView.convert(point, from: container)
        guard let proposal = hit.dropProposal(for: payload, at: local, in: snapshot) else {
            // Inside a placeholder: keep the current proposal.
            if verdict == nil { hit.showDropFeedback(nil, isValid: false, payload: payload) }
            return verdict
        }
        let error = Self.validate(payload, to: proposal.destination, snapshot: snapshot, catalog: catalog)
        let next = Verdict(proposal: proposal, error: error)
        if next != verdict { hit.showDropFeedback(proposal, isValid: error == nil, payload: payload) }
        verdict = next
        return next
    }

    /// Rows move between windows of one Space only (SB-LIST contract): another profile is a
    /// cross-profile move, another Space of the profile is not visible in this context — shared
    /// Favorites included, whose payload carries the source window's Space. The store repeats the
    /// model checks authoritatively when the command runs.
    static func validate(_ payload: SidebarDragPayload, to destination: BrowserOrganizationDestination,
                         snapshot: BrowserOrganizationSnapshot, catalog: BrowserCatalogSnapshot) -> BrowserOrganizationError? {
        guard payload.profileID == snapshot.profileID else { return .crossProfileMove }
        guard payload.spaceID == snapshot.spaceID else { return .notVisibleInContext }
        return snapshot.validateMove(payload.nodes, to: destination, catalog: catalog)
    }

    /// Accepted drop, or nil when the last verdict refused it.
    func acceptedDrop() -> (payload: SidebarDragPayload, proposal: SidebarDropProposal, target: any SidebarDropTarget)? {
        guard let payload, let verdict, verdict.isValid, let target else { return nil }
        return (payload, verdict.proposal, target)
    }

    /// The drag left or was refused: the target drops its feedback.
    func clear() {
        target?.showDropFeedback(nil, isValid: false, payload: nil)
        finish()
    }

    /// The drop was committed: the target keeps its feedback until the update arrives.
    func finish() {
        target = nil
        payload = nil
        verdict = nil
    }
}

/// Bridges the FAVORITES lot's `FavoritesDropTarget` adapter into the shared coordinator: the
/// potential Favorites zone (between the address field and the Space title, the grid itself when
/// it has tiles) reveals the empty drop row on entry, previews through the adapter, and the
/// adapter commits the drop with FAVORITES' own revalidation (docs/native-port/favorites-2026-10-25.md).
@MainActor
final class SidebarFavoritesDropTarget: SidebarDropTarget {
    private weak var grid: FavoritesGridView?
    private weak var sidebar: BrowserSidebarView?
    private var isRevealed = false
    private var lastPoint = NSPoint.zero

    init(grid: FavoritesGridView, sidebar: BrowserSidebarView) {
        self.grid = grid
        self.sidebar = sidebar
    }

    var dropTargetView: NSView { grid ?? NSView() }

    func acceptsDrag(at point: NSPoint, in container: NSView) -> Bool {
        guard let sidebar, let grid, grid.window != nil, !sidebar.isPresentationHidden else { return false }
        let local = sidebar.convert(point, from: container)
        let geometry = sidebar.geometry
        let top = geometry.addressFrame.maxY
        let bottom = geometry.pageFrame.minY + geometry.spaceTitleCenterY
        return local.y >= top && local.y < bottom && local.x >= 0 && local.x <= sidebar.bounds.width
    }

    func dropProposal(for payload: SidebarDragPayload, at point: NSPoint,
                      in snapshot: BrowserOrganizationSnapshot) -> SidebarDropProposal? {
        guard let grid else { return nil }
        lastPoint = point
        if !isRevealed {
            isRevealed = true
            grid.dropTarget.begin()
        }
        // Folders and other profiles get the section root: `validateMove` refuses them visibly.
        let destination = grid.dropTarget.destination(Self.favoritesPayload(payload), at: point)
            ?? BrowserOrganizationDestination(.favorites(snapshot.profileID))
        return SidebarDropProposal(destination: destination, gap: nil, folderTarget: nil)
    }

    func showDropFeedback(_ proposal: SidebarDropProposal?, isValid: Bool, payload: SidebarDragPayload?) {
        guard let adapter = grid?.dropTarget else { return }
        if proposal == nil, payload == nil {
            if isRevealed { adapter.end() }
            isRevealed = false
        } else if isValid, let payload {
            isRevealed = adapter.update(Self.favoritesPayload(payload), at: lastPoint)
        } else {
            grid?.clearDropPreview()
            adapter.onPreviewCountChange?(nil)
        }
    }

    func didAcceptDrop(_ proposal: SidebarDropProposal, payload: SidebarDragPayload, changesOrganization: Bool) -> Bool {
        isRevealed = false
        grid?.dropTarget.end()
        // The shared sidebar path commits the validated destination AND transfers live documents.
        // Calling adapter.perform here loses the source window and bypasses that transfer.
        return false
    }

    func sidebarDragDidChange(_ payload: SidebarDragPayload?) {
        guard payload == nil, isRevealed else { return }
        isRevealed = false
        grid?.dropTarget.end()
    }

    static func favoritesPayload(_ payload: SidebarDragPayload) -> FavoritesDragPayload {
        FavoritesDragPayload(profileID: payload.profileID, nodes: payload.nodes)
    }
}

extension SidebarDragPayload {
    /// A Favorites tile dragged from the grid of `sourceWindow` (FAVORITES' payload carries no
    /// Space). The Space is the source window's active one; nil when that window is unknown, so
    /// an unattributed tile is refused rather than adopting the destination's Space.
    @MainActor
    init?(favorites payload: FavoritesDragPayload, sourceWindow: UUID?) {
        guard let sourceWindow, let spaceID = SidebarWindowDirectory.activeSpace(of: sourceWindow) else { return nil }
        self.init(sourceWindow: sourceWindow, spaceID: spaceID, profileID: payload.profileID, nodes: payload.nodes,
                  rowCount: max(1, payload.nodes.count), grabOffsetX: 0)
    }
}
