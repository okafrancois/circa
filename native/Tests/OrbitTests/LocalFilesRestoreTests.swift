import AppKit
@testable import BrowserCore
import BrowserEngine
import BrowserShell
import Darwin
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct LocalFilesRestoreTests {
    private func fixture(_ body: @MainActor (URL, URL) async throws -> Void) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("local-restore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("document.pdf")
        let second = root.appendingPathComponent("neighbor.pdf")
        try Data("%PDF-1.4\nsynthetic".utf8).write(to: first)
        try Data("%PDF-1.4\nneighbor".utf8).write(to: second)
        try await body(first.standardizedFileURL, second.standardizedFileURL)
    }

    private func engine() -> PeekSyntheticEngine {
        let engine = PeekSyntheticEngine()
        engine.programmaticNavigationKind = .typed
        return engine
    }

    private func restored(_ document: BrowserSessionDocument) throws -> BrowserWindowController<PeekSyntheticEngine> {
        let window = try #require(document.windows.first)
        return BrowserWindowController(id: UUID(), store: try BrowserStore(restoring: document),
            spaceID: window.activeSpaceID, engine: engine(), restoringWindowID: window.id,
            opensInitialTab: false, onClose: {}, onActivate: {})
    }

    private func allows(_ url: URL, owner: BrowserWindowController<PeekSyntheticEngine>,
                        surface: PeekSyntheticSurface, kind: BrowserNavigationKind = .reload,
                        main: Bool = true) -> Bool {
        owner.navigationActionPolicy(for: .init(url: url, isMainFrame: main, kind: kind), in: surface) == .allow
    }

    @Test("Local session persistence reissues consent only for the restored document")
    func persistedRelaunch() async throws {
        try await fixture { file, neighbor in
            let environment = BrowserEnvironment(engine: engine())
            let owner = try await environment.makeWindow()
            owner.openLocalFiles([file])
            await owner.session.waitForPendingCommands()
            let document = await environment.store.sessionDocument()
            let parent = try #require(realpath(file.deletingLastPathComponent().path, nil))
            defer { free(parent) }
            let destination = URL(fileURLWithPath: String(cString: parent)).appendingPathComponent("session.json")
            let persistence = BrowserSessionFileStore()
            _ = try persistence.save(document, to: destination)
            owner.session.retireForApplicationTermination()
            owner.window?.close()
            let relaunched = try restored(persistence.load(from: destination))
            defer { relaunched.window?.close() }
            await relaunched.session.waitForPendingCommands()
            let surface = try #require(relaunched.session.selectedSurface)
            #expect(surface.navigationState.committedURL == file)
            #expect(allows(file, owner: relaunched, surface: surface))
            #expect(!allows(neighbor, owner: relaunched, surface: surface))
            #expect(relaunched.session.localDocument(for: surface)?.canonicalPath == BrowserLocalDocument.canonicalPath(for: file))
            // Opening a second model tab at the same URL must not inherit another tab's consent.
            relaunched.session.openTab(url: file)
            await relaunched.session.waitForPendingCommands()
            let untrusted = try #require(relaunched.session.selectedSurface)
            #expect(!allows(file, owner: relaunched, surface: untrusted))
        }
    }

    @Test("Unloaded local tabs regain exact consent on wake")
    func unloadWake() async throws {
        try await fixture { file, neighbor in
            let environment = BrowserEnvironment(engine: engine())
            let owner = try await environment.makeWindow()
            defer { owner.window?.close() }
            owner.openLocalFiles([file])
            await owner.session.waitForPendingCommands()
            let sleeping = try #require(owner.session.selectedSurface)
            let occurrence = try #require(owner.session.occurrenceID(for: sleeping))
            owner.openTab(url: URL(string: "https://synthetic.invalid/")!)
            await owner.session.waitForPendingCommands()
            #expect(owner.session.suspendSurface(sleeping))
            #expect(sleeping.isDisposed)
            owner.session.selectOccurrence(occurrence)
            await owner.session.waitForPendingCommands()
            let awake = try #require(owner.session.selectedSurface)
            #expect(awake !== sleeping)
            #expect(awake.navigationState.committedURL == file)
            owner.reload()
            await owner.session.waitForPendingCommands()
            #expect(allows(file, owner: owner, surface: awake))
            #expect(!allows(neighbor, owner: owner, surface: awake))
        }
    }

    @Test("Native discard and wake preserve document consent without URL replay")
    func discardWake() async throws {
        try await fixture { file, neighbor in
            let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
            let owner = try await environment.makeWindow()
            defer { owner.window?.close() }
            owner.openLocalFiles([file])
            await owner.session.waitForPendingCommands()
            let surface = try #require(owner.session.selectedSurface)
            let occurrence = try #require(owner.session.occurrenceID(for: surface))
            surface.allowsSuspension = true
            owner.openTab(url: URL(string: "https://synthetic.invalid/")!)
            await owner.session.waitForPendingCommands()
            #expect(owner.session.suspendSurface(surface))
            surface.isSuspended = true
            owner.session.selectOccurrence(occurrence)
            await owner.session.waitForPendingCommands()
            #expect(owner.session.selectedSurface === surface && !surface.isDisposed)
            surface.isSuspended = false
            #expect(owner.navigationActionPolicy(for: .init(url: file, isMainFrame: true, kind: .reload), in: surface) == .allow)
            #expect(owner.navigationActionPolicy(for: .init(url: neighbor, isMainFrame: true, kind: .reload), in: surface) == .cancel)
        }
    }

    @Test("Duplication and same-profile window transfer retain exact document provenance")
    func duplicateAndMove() async throws {
        try await fixture { file, neighbor in
            let environment = BrowserEnvironment(engine: engine())
            let owner = try await environment.makeWindow()
            let destination = try await environment.makeWindow()
            defer { owner.window?.close(); destination.window?.close() }
            owner.openLocalFiles([file])
            await owner.session.waitForPendingCommands()
            let original = try #require(owner.session.selectedSurface)
            owner.session.duplicateSelectedTab()
            await owner.session.waitForPendingCommands()
            let copy = try #require(owner.session.selectedSurface)
            #expect(copy !== original && copy.navigationState.committedURL == file)
            #expect(owner.session.localDocument(for: copy) == owner.session.localDocument(for: original))
            let move = try #require(owner.moveSurface(copy, to: destination))
            _ = try #require(await move.value)
            await destination.session.waitForPendingCommands()
            #expect(destination.session.selectedSurface === copy)
            #expect(allows(file, owner: destination, surface: copy))
            #expect(!allows(neighbor, owner: destination, surface: copy))
            #expect(destination.session.localDocument(for: copy) != nil)
        }
    }

    @Test("Archive and last-closed restoration preserve consent through session serialization", arguments: [false, true])
    func archiveRestore(lastClosed: Bool) async throws {
        try await fixture { file, _ in
            let environment = BrowserEnvironment(engine: engine())
            let owner = try await environment.makeWindow()
            defer { owner.window?.close() }
            owner.openLocalFiles([file])
            await owner.session.waitForPendingCommands()
            let id = try #require(owner.session.snapshot?.tabs.last?.id)
            if lastClosed { owner.session.closeSelectedTab() } else { owner.session.archiveTabs([id]) }
            await owner.session.waitForPendingCommands()
            let document = try BrowserSessionDocument.decode(await environment.store.sessionDocument().encoded())
            #expect(document.organization.archive.first { $0.id == id }?.tab.localDocument != nil)
            let relaunched = try restored(document)
            defer { relaunched.window?.close() }
            await relaunched.session.waitForPendingCommands()
            if lastClosed { relaunched.session.restoreMostRecentArchivedTab() }
            else { relaunched.session.restoreArchivedTab(id) }
            await relaunched.session.waitForPendingCommands()
            let surface = try #require(relaunched.session.selectedSurface)
            #expect(surface.navigationState.committedURL == file)
            #expect(allows(file, owner: relaunched, surface: surface))
        }
    }

    @Test("A deleted or moved document is still admitted to the engine's missing-file handling", arguments: [false, true])
    func missingFile(moved: Bool) async throws {
        try await fixture { file, _ in
            let environment = BrowserEnvironment(engine: engine())
            let owner = try await environment.makeWindow()
            defer { owner.window?.close() }
            owner.openLocalFiles([file])
            await owner.session.waitForPendingCommands()
            let document = try BrowserSessionDocument.decode(await environment.store.sessionDocument().encoded())
            if moved { try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("moved")) }
            else { try FileManager.default.removeItem(at: file) }
            let relaunched = try restored(document)
            defer { relaunched.window?.close() }
            await relaunched.session.waitForPendingCommands()
            let surface = try #require(relaunched.session.selectedSurface)
            #expect(surface.requestedURLs.contains(file))
            #expect(allows(file, owner: relaunched, surface: surface))
        }
    }

    @Test("Restored grants refuse model-only URLs, other profiles, pages, redirects and subframes")
    func negativeBoundaries() async throws {
        try await fixture { file, neighbor in
            let environment = BrowserEnvironment(engine: engine())
            let owner = try await environment.makeWindow()
            defer { owner.window?.close() }
            owner.session.openTab(url: file)
            await owner.session.waitForPendingCommands()
            let untrusted = try restored(BrowserSessionDocument.decode(await environment.store.sessionDocument().encoded()))
            defer { untrusted.window?.close() }
            await untrusted.session.waitForPendingCommands()
            let surface = try #require(untrusted.session.selectedSurface)
            #expect(!allows(file, owner: untrusted, surface: surface))
            owner.openLocalFiles([file])
            await owner.session.waitForPendingCommands()
            let granted = try #require(owner.session.selectedSurface)
            let provenance = try #require(owner.session.localDocument(for: granted))
            #expect(!provenance.matches(file, profileID: ProfileID()))
            #expect(!provenance.matches(neighbor, profileID: granted.profileID))
            for kind: BrowserNavigationKind in [.linkActivation, .redirect, .other, .formSubmission] {
                #expect(!allows(file, owner: owner, surface: granted, kind: kind))
            }
            #expect(!allows(file, owner: owner, surface: granted, main: false))
            granted.navigate(to: URL(string: "https://synthetic.invalid/")!)
            await owner.session.waitForPendingCommands()
            let web = try restored(BrowserSessionDocument.decode(await environment.store.sessionDocument().encoded()))
            defer { web.window?.close() }
            await web.session.waitForPendingCommands()
            let webSurface = try #require(web.session.selectedSurface)
            #expect(BrowserNavigationPolicy.action(.init(url: file, isMainFrame: true, kind: .typed), surface: webSurface,
                held: true, routesEnabled: false, hooks: web.engineEventHooks) == .cancel)
        }
    }

    @Test("A changed model target cannot reuse the saved document's consent")
    func differentModelTarget() async throws {
        try await fixture { file, neighbor in
            let environment = BrowserEnvironment(engine: engine())
            let owner = try await environment.makeWindow()
            defer { owner.window?.close() }
            owner.openLocalFiles([file])
            await owner.session.waitForPendingCommands()
            let surface = try #require(owner.session.selectedSurface)
            owner.session.updateDestination(for: surface, to: neighbor)
            await owner.session.waitForPendingCommands()
            let relaunched = try restored(BrowserSessionDocument.decode(await environment.store.sessionDocument().encoded()))
            defer { relaunched.window?.close() }
            await relaunched.session.waitForPendingCommands()
            let restoredSurface = try #require(relaunched.session.selectedSurface)
            #expect(restoredSurface.navigationState.committedURL == nil)
            #expect(!allows(neighbor, owner: relaunched, surface: restoredSurface))
            #expect(BrowserNavigationPolicy.action(.init(url: file, isMainFrame: true, kind: .typed), surface: restoredSurface,
                held: true, routesEnabled: false, hooks: relaunched.engineEventHooks) == .cancel)
        }
    }

    @Test("Symlink replacements never change the recorded canonical document", arguments: [false, true])
    func symlinkSwap(alias: Bool) async throws {
        try await fixture { file, neighbor in
            let input = alias ? file.appendingPathExtension("link") : file
            if alias { try FileManager.default.createSymbolicLink(at: input, withDestinationURL: file) }
            let environment = BrowserEnvironment(engine: engine())
            let owner = try await environment.makeWindow()
            defer { owner.window?.close() }
            owner.openLocalFiles([input])
            await owner.session.waitForPendingCommands()
            let document = try BrowserSessionDocument.decode(await environment.store.sessionDocument().encoded())
            try FileManager.default.removeItem(at: input)
            try FileManager.default.createSymbolicLink(at: input, withDestinationURL: neighbor)
            let relaunched = try restored(document)
            defer { relaunched.window?.close() }
            await relaunched.session.waitForPendingCommands()
            let surface = try #require(relaunched.session.selectedSurface)
            #expect(!allows(input, owner: relaunched, surface: surface))
            #expect(!allows(neighbor, owner: relaunched, surface: surface))
        }
    }

    @Test("Typed and dropped native input persist per-tab consent", arguments: [false, true])
    func nativeProvenance(drop: Bool) async throws {
        try await fixture { file, _ in
            let environment = BrowserEnvironment(engine: engine())
            let owner = try await environment.makeWindow()
            defer { owner.window?.close() }
            await owner.session.waitForPendingCommands()
            if drop { #expect(owner.surface(try #require(owner.session.selectedSurface), openDroppedFiles: [file])) }
            else { owner.submitAddress(file.path) }
            await owner.session.waitForPendingCommands()
            let relaunched = try restored(BrowserSessionDocument.decode(await environment.store.sessionDocument().encoded()))
            defer { relaunched.window?.close() }
            await relaunched.session.waitForPendingCommands()
            #expect(relaunched.session.selectedSurface?.navigationState.committedURL == file)
        }
    }

    @Test("Sync and bookmark exports exclude native document consent; imported links stay untrusted")
    func syncAndExport() async throws {
        try await fixture { file, _ in
            let environment = BrowserEnvironment(engine: engine())
            let owner = try await environment.makeWindow()
            defer { owner.window?.close() }
            owner.openLocalFiles([file])
            await owner.session.waitForPendingCommands()
            let id = try #require(owner.session.snapshot?.tabs.last?.id)
            owner.session.pinTabs([id])
            await owner.session.waitForPendingCommands()
            let document = await environment.store.sessionDocument()
            let projection = try BrowserSyncMapping.project(session: document, settings: .init())
            #expect(projection.entries.values.allSatisfy { $0["localDocument"] == nil })
            var replica = BrowserSyncReplica(device: "synthetic")
            try replica.capture(projection, now: Date())
            let retained = try BrowserSyncMapping.materialize(replica.visible, local: document, settings: .init())
            #expect(retained.organization.tabs.first { $0.id == id }?.localDocument != nil)
            // Even a peer supplying an unknown consent field cannot authorize a local document.
            var foreign = replica.visible
            let key = "tab/" + id.rawValue.uuidString
            let consent = try #require(document.organization.tabs.first { $0.id == id }?.localDocument)
            foreign[key]?["localDocument"] = try JSONEncoder().encode(consent)
            foreign[key]?["localDocument.canonicalPath"] = try JSONEncoder().encode(consent.canonicalPath)
            let empty = BrowserSessionDocument(profiles: document.profiles, spaces: document.spaces, windows: [], tabs: [])
            let remote = try BrowserSyncMapping.materialize(foreign, local: empty, settings: .init())
            #expect(remote.organization.tabs.allSatisfy { $0.localDocument == nil })
            let context = try await environment.store.captureContext(in: #require(owner.session.snapshot?.id))
            let exported = try await environment.store.exportBookmarks(from: context)
            let bytes = try BrowserBookmarkHTML.encode(exported)
            #expect(!String(decoding: bytes, as: UTF8.self).contains("localDocument"))
            let imported = BrowserBookmarkDocument(entries: [.link(title: "Synthetic", url: URL(string: "https://synthetic.invalid/")!)])
            _ = try await environment.store.importBookmarks(imported, folderTitle: "Imported", from: context)
            let after = await environment.store.sessionDocument()
            #expect(after.organization.tabs.filter { $0.id != id }.allSatisfy { $0.localDocument == nil })
        }
    }
}
}
