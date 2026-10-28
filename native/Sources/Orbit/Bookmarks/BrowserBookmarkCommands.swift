import BrowserEngine

/// Portable-file commands are an explicit reconstruction for CORE-BOOKMARKS;
/// they do not change Orbit's serialized menu observations or claim Orbit fidelity.
enum BrowserBookmarkCommands {
    static let definitions: [BrowserCommandDefinition] = [
        .init(id: .importBookmarks, title: "Import Bookmarks…", menu: "File", shortcuts: [], scope: .browser,
              requirement: .window, owner: "BOOKMARKS", sources: ["Reconstruction: portable Netscape HTML import"]),
        .init(id: .exportBookmarks, title: "Export Bookmarks…", menu: "File", shortcuts: [], scope: .browser,
              requirement: .window, owner: "BOOKMARKS", sources: ["Reconstruction: profile-scoped saved links export"])
    ]

    @MainActor
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        for id in [BrowserCommandID.importBookmarks, .exportBookmarks] {
            registry.registerPrerequisite(id) { owner, _ in owner?.bookmarkTransfer?.isBusy != true }
            try! registry.register(id, validate: { $0.bookmarkTransfer?.isBusy != true }) { owner, _ in
                guard owner.acceptsCommands, !owner.isPreparingForTermination else { return }
                if owner.bookmarkTransfer == nil { owner.bookmarkTransfer = BrowserBookmarkTransferController(owner: owner) }
                if id == .importBookmarks { owner.bookmarkTransfer?.startImport() }
                else { owner.bookmarkTransfer?.startExport() }
            }
        }
    }
}
