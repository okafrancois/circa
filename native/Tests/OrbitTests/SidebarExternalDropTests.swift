import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SidebarExternalDropTests {
    private typealias Owner = BrowserWindowController<PeekSyntheticEngine>

    private func fixture(_ body: @MainActor (Owner, URL, URL, NSPasteboard, NSPoint) async throws -> Void) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-drops-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("document.pdf"), html = root.appendingPathComponent("other.html")
        try Data("%PDF-1.4\nsynthetic".utf8).write(to: pdf)
        try Data("<title>Synthetic</title>".utf8).write(to: html)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); owner.session.close(); owner.window?.close() }
        owner.session.openTab(url: URL(string: "https://synthetic.invalid/source")!)
        await owner.session.waitForPendingCommands()
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        let list = owner.sidebar.page.list
        let point = owner.sidebar.convert(NSPoint(x: 100, y: list.bounds.maxY - 10), from: list)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try await body(owner, pdf, html, pasteboard, point)
        #expect(owner.window?.isVisible == false)
    }

    private func info(_ owner: Owner, _ pasteboard: NSPasteboard, _ point: NSPoint, source: Any? = nil) throws -> SidebarExternalDraggingInfo {
        SidebarExternalDraggingInfo(window: try #require(owner.window), pasteboard: pasteboard, source: source,
            location: owner.sidebar.convert(point, to: nil))
    }

    private func policy(_ owner: Owner, _ url: URL, surface: PeekSyntheticSurface) -> BrowserNavigationActionPolicy {
        BrowserNavigationPolicy.action(.init(url: url, isMainFrame: true, kind: .typed), surface: surface,
            held: true, routesEnabled: false, hooks: owner.engineEventHooks)
    }

    @Test("Sidebar and Favorites payloads take precedence over file, URL and text representations", arguments: [false, true])
    func internalPrecedence(favorites: Bool) async throws {
        try await fixture { owner, pdf, _, pasteboard, point in
            let organization = try #require(owner.session.organization)
            let tab = try #require(organization.selectedTab)
            let payload = SidebarDragPayload(sourceWindow: owner.id, spaceID: organization.spaceID,
                profileID: organization.profileID, nodes: [.tab(tab.id)], rowCount: 1, grabOffsetX: 0)
            let favorite = FavoritesDragPayload(profileID: organization.profileID, nodes: payload.nodes)
            let source = SidebarExternalFavoritesSource(payload: favorite)
            owner.window?.contentView?.addSubview(source)
            let item = favorites ? NSPasteboardItem() : payload.pasteboardItem()
            if favorites { item.setData(try JSONEncoder().encode(favorite), forType: FavoritesDragPayload.pasteboardType) }
            item.setString(pdf.absoluteString, forType: .fileURL)
            item.setString("https://synthetic.invalid/link", forType: .URL)
            item.setString("synthetic search", forType: .string)
            #expect(pasteboard.writeObjects([item]))
            var moved: [BrowserOrganizationNode] = []
            var externalCalls = 0
            owner.sidebar.onDrop = { payload, _, _ in moved = payload.nodes }
            owner.sidebar.onCopyDrop = { payload, _ in moved = payload.nodes }
            owner.sidebar.onFileDrop = { _, _ in externalCalls += 1 }
            owner.sidebar.onTextDrop = { _, _ in externalCalls += 1 }
            let drag = try info(owner, pasteboard, point, source: favorites ? source : owner.sidebar.page.list)
            #expect(!owner.sidebar.draggingEntered(drag).isEmpty)
            #expect(owner.sidebar.prepareForDragOperation(drag))
            #expect(owner.sidebar.performDragOperation(drag))
            #expect(moved == payload.nodes)
            #expect(externalCalls == 0)
            #expect(consentedDocuments(owner).isEmpty)
        }
    }

    @Test("Untrusted internal representations cannot fall through to an external file grant", arguments: [false, true])
    func refusedInternal(favorites: Bool) async throws {
        try await fixture { owner, pdf, _, pasteboard, point in
            let item = NSPasteboardItem()
            item.setData(Data("invalid".utf8), forType: favorites ? FavoritesDragPayload.pasteboardType : SidebarDragPayload.pasteboardType)
            item.setString(pdf.absoluteString, forType: .fileURL)
            item.setString("https://synthetic.invalid/link", forType: .URL)
            #expect(pasteboard.writeObjects([item]))
            let drag = try info(owner, pasteboard, point)
            #expect(owner.sidebar.draggingEntered(drag).isEmpty)
            #expect(!owner.sidebar.prepareForDragOperation(drag))
            #expect(!owner.sidebar.performDragOperation(drag))
            #expect(consentedDocuments(owner).isEmpty)
        }
    }

    @Test("Explicit file items outrank URL and text, grant only at drop and only to the new surface")
    func filePrecedenceAndGrants() async throws {
        try await fixture { owner, pdf, html, pasteboard, point in
            let original = try #require(owner.session.selectedSurface)
            let item = NSPasteboardItem()
            item.setString(pdf.absoluteString, forType: .fileURL)
            item.setString("https://synthetic.invalid/link", forType: .URL)
            item.setString("synthetic search", forType: .string)
            // A second item's URL representation must not be coerced into another file grant.
            let other = NSPasteboardItem()
            other.setString(html.absoluteString, forType: .URL)
            #expect(pasteboard.writeObjects([item, other]))
            #expect(BrowserSidebarView.droppedFiles(pasteboard) == [pdf])
            let before = owner.session.snapshot?.tabs.count
            let drag = try info(owner, pasteboard, point)
            #expect(owner.sidebar.draggingEntered(drag) == .copy)
            #expect(owner.sidebar.draggingUpdated(drag) == .copy)
            #expect(owner.sidebar.prepareForDragOperation(drag))
            #expect(consentedDocuments(owner).isEmpty)
            #expect(policy(owner, pdf, surface: original) == .cancel)
            #expect(owner.session.snapshot?.tabs.count == before)
            #expect(owner.sidebar.performDragOperation(drag))
            await owner.session.waitForPendingCommands()
            let opened = try #require(owner.session.selectedSurface)
            #expect(opened !== original)
            #expect(owner.session.organization?.selectedTab?.url == pdf)
            #expect(owner.session.snapshot?.tabs.count == before.map { $0 + 1 })
            #expect(consentedDocuments(owner) == [BrowserLocalDocument.canonicalPath(for: pdf)])
            #expect(policy(owner, pdf, surface: opened) == .allow)
            #expect(policy(owner, html, surface: opened) == .cancel)
            #expect(policy(owner, pdf, surface: original) == .cancel)
        }
    }

    @Test("Web URLs outrank plain text and plain text uses the configured search engine", arguments: [false, true])
    func webAndTextPrecedence(web: Bool) async throws {
        try await fixture { owner, _, _, pasteboard, point in
            owner.addressResolver = AddressResolver(searchEngine: .duckDuckGo)
            let item = NSPasteboardItem()
            let url = URL(string: "https://synthetic.invalid/link")!
            if web { item.setString(url.absoluteString, forType: .URL) }
            item.setString("synthetic search", forType: .string)
            #expect(pasteboard.writeObjects([item]))
            let drag = try info(owner, pasteboard, point)
            #expect(owner.sidebar.draggingEntered(drag) == .copy)
            #expect(owner.sidebar.prepareForDragOperation(drag))
            #expect(owner.sidebar.performDragOperation(drag))
            await owner.session.waitForPendingCommands()
            #expect(owner.session.selectedSurface?.currentURL == (web ? url : SearchEngine.duckDuckGo.searchURL(for: "synthetic search")))
            #expect(consentedDocuments(owner).isEmpty)
        }
    }

    @Test("File URLs carried as URL or text never acquire grants, even after native reopening", arguments: [false, true])
    func textCannotGrant(urlRepresentation: Bool) async throws {
        try await fixture { owner, pdf, _, pasteboard, point in
            let original = try #require(owner.session.selectedSurface)
            let item = NSPasteboardItem()
            item.setString(pdf.absoluteString, forType: urlRepresentation ? .URL : .string)
            #expect(pasteboard.writeObjects([item]))
            #expect(BrowserSidebarView.droppedFiles(pasteboard).isEmpty)
            let drag = try info(owner, pasteboard, point)
            #expect(owner.sidebar.draggingEntered(drag).isEmpty)
            #expect(!owner.sidebar.prepareForDragOperation(drag))
            #expect(!owner.sidebar.performDragOperation(drag))
            #expect(consentedDocuments(owner).isEmpty)
            #expect(policy(owner, pdf, surface: original) == .cancel)
            owner.openLocalFiles([pdf])
            await owner.session.waitForPendingCommands()
            let granted = try #require(owner.session.selectedSurface)
            #expect(policy(owner, pdf, surface: granted) == .allow)
            let before = owner.session.snapshot?.tabs.count
            #expect(owner.sidebar.draggingEntered(drag).isEmpty)
            #expect(!owner.sidebar.performDragOperation(drag))
            // The command callback also rejects text, even if called without AppKit validation.
            owner.sidebar.onTextDrop?(pdf.absoluteString, .init(.today(owner.session.snapshot!.activeSpaceID)))
            await owner.session.waitForPendingCommands()
            #expect(owner.session.snapshot?.tabs.count == before)
            #expect(policy(owner, pdf, surface: original) == .cancel)
        }
    }

    @Test("Completed pasteboard content is revalidated after file hover")
    func changedPasteboard() async throws {
        try await fixture { owner, pdf, _, pasteboard, point in
            #expect(pasteboard.writeObjects([pdf as NSURL]))
            let drag = try info(owner, pasteboard, point)
            #expect(owner.sidebar.draggingEntered(drag) == .copy)
            #expect(owner.sidebar.prepareForDragOperation(drag))
            pasteboard.clearContents()
            pasteboard.setString(pdf.absoluteString, forType: .string)
            #expect(!owner.sidebar.performDragOperation(drag))
            #expect(!owner.sidebar.commitExternalDrop())
            #expect(consentedDocuments(owner).isEmpty)
        }
    }

    @Test("Cancellation and disabled commands discard external feedback without opening files")
    func cancelledOrDisabled() async throws {
        try await fixture { owner, pdf, _, pasteboard, point in
            #expect(pasteboard.writeObjects([pdf as NSURL]))
            let drag = try info(owner, pasteboard, point)
            #expect(owner.sidebar.draggingEntered(drag) == .copy)
            owner.sidebar.draggingExited(drag)
            #expect(!owner.sidebar.prepareForDragOperation(drag))
            #expect(!owner.sidebar.commitExternalDrop())
            #expect(owner.sidebar.draggingEntered(drag) == .copy)
            owner.sidebar.setCommandsEnabled(false)
            #expect(!owner.sidebar.performDragOperation(drag))
            #expect(!owner.sidebar.prepareForDragOperation(drag))
            #expect(consentedDocuments(owner).isEmpty)
        }
    }
}
}

@MainActor
private final class SidebarExternalFavoritesSource: NSView, FavoritesLocalDragSource {
    let favoritesDragPayload: FavoritesDragPayload?
    init(payload: FavoritesDragPayload) { favoritesDragPayload = payload; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
}

/// Destination-protocol fixture; no OS events, visible windows or general pasteboard.
@MainActor
private final class SidebarExternalDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingLocation: NSPoint
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(window: NSWindow, pasteboard: NSPasteboard, source: Any?, location: NSPoint) {
        draggingDestinationWindow = window; draggingPasteboard = pasteboard
        draggingSource = source; draggingLocation = location
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

/// Paths with durable user consent across every tab of the window's organization.
@MainActor
private func consentedDocuments<Engine: BrowserEngine>(_ owner: BrowserWindowController<Engine>) -> Set<String> {
    Set(owner.session.organization?.allTabs.compactMap { $0.localDocument?.canonicalPath } ?? [])
}
