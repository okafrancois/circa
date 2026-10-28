import BrowserCore
import BrowserEngine
import Foundation

@MainActor
enum BrowserPasswordCommands {
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        try! registry.register(.openPasswordManager, validate: {
            $0.engine.kind == .chromium && !$0.isPrivateWindow && $0.session.activeProfileID != nil
        }) { controller, _ in
            guard let profile = controller.session.activeProfileID else { return }
            Task { @MainActor [weak controller] in
                guard let controller else { return }
                do { try await controller.openPasswordManager(profile: profile) }
                catch { controller.session.onError?(error) }
            }
        }
    }
}

extension BrowserWindowController {
    /// Open a separate, profile-bound WebUI tab. Chromium owns its settings, store, import/export,
    /// authentication and renderer agents; the shell does not read or fill credentials.
    func openPasswordManager(profile: ProfileID) async throws {
        guard acceptsCommands, !isPrivateWindow, engine.kind == .chromium,
              session.activeProfileID == profile,
              let tab = await session.openTabForDelivery(url: URL(string: "about:blank")!, expectedProfileID: profile).value,
              let surface = session.selectedSurface, surface.profileID == profile,
              session.snapshot?.selectedOccurrenceID == tab.occurrenceID else {
            throw BrowserEngineError.unsupportedOperation
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !surface.isReady, !surface.isDisposed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard acceptsCommands, !surface.isDisposed, surface.isReady, owns(surface),
              session.selectedSurface === surface, session.activeProfileID == profile else {
            throw BrowserEngineError.unsupportedOperation
        }
        BrowserNavigationPolicy.authorizePasswordManager(for: surface)
        surface.navigate(to: URL(string: "chrome://password-manager/passwords")!)
    }
}
