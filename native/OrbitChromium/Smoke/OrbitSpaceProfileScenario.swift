import AppKit
import BrowserCore
import ChromiumEngine
import Foundation

/// Synthetic-only hook: exercises the internal operation through the synthetic driver.
@MainActor
enum OrbitSpaceProfileScenario {
    static func run(environment: OrbitEnvironment, window: OrbitWindowController, fixture: URL,
                    record: (String, String, [String: Any]) -> Void) async {
        func check(_ name: String, _ value: Bool) { record("space-profile." + name, value ? "proven" : "failed", [:]) }
        let page = URL(string: "/page?case=space-profile", relativeTo: fixture)!.absoluteURL
        let origin = URL(string: "/", relativeTo: fixture)!.absoluteURL
        var contextErrors = 0
        let previousErrorHandler = window.session.onError
        window.session.onError = { _ in contextErrors += 1 }
        defer { window.session.onError = previousErrorHandler }
        do {
            window.submitAddress(page.absoluteString)
            await window.session.waitForPendingCommands()
            guard await ready(window, page), let old = window.session.selectedSurface,
                  let context = await window.session.captureContextInCommandOrder().value, let probe = environment.engine.conformanceProbe else {
                check("source-ready", false); return
            }
            let a = context.profileID, space = context.spaceID
            let b = await environment.store.createProfile(name: "Synthetic Target Profile")
            let bSpace = try await environment.store.createSpace(name: "Synthetic Target Home", profileID: b)
            // Establish different cookies and DOM storage on the very same origin before moving.
            try await probe.writeSiteDataMarker("synthetic-A", for: origin, through: old)
            _ = try await probe.evaluateScript("localStorage.setItem('space-profile', 'synthetic-A'); 'ok'", in: old)
            let tab = try requireTab(window)
            _ = try await environment.store.pinTabs([tab], from: environment.store.captureContext(in: context.windowID))
            let (folder, _) = try await environment.store.createFolder(title: "Synthetic retained folder", at: .init(.pinned(space)),
                containing: [.tab(tab)], from: environment.store.captureContext(in: context.windowID))
            window.openTab(url: page)
            await window.session.waitForPendingCommands()
            guard await ready(window, page) else { check("today-ready", false); return }
            let before = await environment.store.sessionDocument()
            window.session.activateSpace(bSpace)
            await window.session.waitForPendingCommands()
            window.openTab(url: page)
            await window.session.waitForPendingCommands()
            guard await ready(window, page), let target = window.session.selectedSurface else { check("target-ready", false); return }
            let blankCookie = try await probe.readSiteDataMarker(for: origin, through: target)
            check("isolated-before", blankCookie != "synthetic-A")
            try await probe.writeSiteDataMarker("synthetic-B", for: origin, through: target)
            _ = try await probe.evaluateScript("localStorage.setItem('space-profile', 'synthetic-B'); 'ok'", in: target)
            window.session.activateSpace(space)
            await window.session.waitForPendingCommands()
            guard let source = window.session.selectedSurface else { check("source-return", false); return }
            let aCookie = try await probe.readSiteDataMarker(for: origin, through: source)
            check("source-cookie-before", aCookie == "synthetic-A" && source.profileID == a)
            let retired = window.session.ownedSurfaces.filter { $0.profileID == a }
            try await environment.moveSpaceToProfile(space, to: b, expectedProfileID: a)
            guard await ready(window, page), let moved = window.session.selectedSurface else { check("move-ready", false); return }
            let cookie = try await probe.readSiteDataMarker(for: origin, through: moved)
            let storage = try await probe.evaluateScript("localStorage.getItem('space-profile')", in: moved)
            check("cookie-and-storage-after", cookie == "synthetic-B" && storage == "synthetic-B" && moved.profileID == b)
            check("old-surfaces-revoked", retired.allSatisfy { !window.session.holds($0) }
                && window.session.ownedSurfaces.allSatisfy { $0.profileID == b })
            let after = await environment.store.sessionDocument()
            try after.validate()
            check("organization-retained", after.organization.folders.contains { $0.id == folder }
                && after.organization.spaces.first { $0.spaceID == space } == before.organization.spaces.first { $0.spaceID == space }
                && after.tabs.filter { $0.spaceID == space }.count == before.tabs.filter { $0.spaceID == space }.count)
            // Switch back to prove the source account still exists and no data was copied/erased.
            try await environment.moveSpaceToProfile(space, to: a, expectedProfileID: b)
            guard await ready(window, page), let returned = window.session.selectedSurface else { check("return-ready", false); return }
            let returnedCookie = try await probe.readSiteDataMarker(for: origin, through: returned)
            check("source-cookie-preserved", returnedCookie == "synthetic-A" && returned.profileID == a)
            try await environment.saveNow()
            check("saved", true)
            await window.session.waitForPendingCommands()
            check("no-context-errors", contextErrors == 0)
        } catch { record("space-profile.operation", "failed", ["kind": String(describing: error)]) }
    }

    private static func ready(_ window: OrbitWindowController, _ url: URL) async -> Bool {
        await OrbitRelaunchScenarios.until {
            window.session.selectedSurface?.isReady == true
                && window.session.selectedSurface?.navigationState.isLoading == false
                && window.session.selectedSurface?.navigationState.committedURL == url
        }
    }

    private static func requireTab(_ window: OrbitWindowController) throws -> TabID {
        guard let id = window.session.snapshot?.selectedOccurrenceID,
              let tab = window.session.snapshot?.tabs.first(where: { $0.occurrenceID == id }) else { throw BrowserStoreError.tabMissing }
        return tab.id
    }
}
