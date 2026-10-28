import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Foundation

/// Installed (not unpacked) CRX fixture; the Python runner owns the server and offline seed.
@MainActor
enum OrbitExtensionUpdateScenario {
    static func run(environment: OrbitEnvironment, window: OrbitWindowController, fixture: URL,
                    record: (String, String, [String: Any]) -> Void) async {
        let driver = OrbitSmokeDriver.shared
        window.submitAddress(fixture.absoluteString)
        await window.session.waitForQueuedCommands()
        guard let surface = window.session.selectedSurface,
              await driver.until(10, { surface.isReady && !surface.navigationState.isLoading }) else {
            record("update.surface", "failed", [:]); return
        }
        record("update.profile", "proven", ["id": surface.profileID.rawValue.uuidString.lowercased()])
        let args = CommandLine.arguments
        if args.contains("--orbit-smoke-extension-update-seed") { return }
        guard let host = environment.engine.extensions else {
            record("update.inventory", "failed", [:]); return
        }
        func fixtureVersion() -> String? {
            try? host.installedExtensions(in: surface.profileID).first { $0.name == "Orbit Update Fixture" && $0.isEnabled }?.version
        }
        if args.contains("--orbit-smoke-extension-update-baseline") || args.contains("--orbit-smoke-extension-update-manual") {
            guard await driver.until(10, { fixtureVersion() == "1.0" }) else {
                record("update.loaded-v1", "failed", ["version": fixtureVersion() ?? "missing"]); return
            }
            record("update.loaded-v1", "proven", ["version": "1.0", "enabled": true])
            if args.contains("--orbit-smoke-extension-update-baseline") { return }
            do {
                guard let manager = environment.engine.extensionManagement,
                      let probe = environment.engine.conformanceProbe else { throw BrowserEngineError.unsupportedOperation }
                window.window?.orderFront(nil)
                guard await driver.until(5, { window.window?.isVisible == true }) else {
                    throw BrowserEngineError.unsupportedOperation
                }
                try manager.openManagement(on: surface)
                guard await driver.until(10, {
                    surface.navigationState.committedURL?.host == "extensions" && !surface.navigationState.isLoading
                }) else { throw BrowserEngineError.unsupportedOperation }
                _ = try await probe.evaluateScript("chrome.developerPrivate.updateProfileConfiguration({inDeveloperMode:true}).then(()=>true)", in: surface)
                // Allow the Lit toolbar to finish reflecting the developer-mode change.
                try? await Task.sleep(for: .milliseconds(500))
                var request = URLRequest(url: fixture.appendingPathComponent("offer2"))
                request.httpMethod = "POST"
                _ = try await URLSession.shared.data(for: request)
                let clicked = try await probe.evaluateScript("""
                    (()=>{const t=document.querySelector('extensions-manager')?.shadowRoot?.querySelector('extensions-toolbar');
                    const b=t?.shadowRoot?.querySelector('#updateNow');
                    if(!b || !t.inDevMode) return 'missing'; b.click(); return 'clicked';})()
                    """, in: surface)
                record("update.manual-button", clicked == "clicked" ? "proven" : "failed", ["result": clicked ?? "missing"])
            } catch {
                record("update.manual-button", "failed", ["error": String(describing: error)]); return
            }
        }
        let updated = await driver.until(25, { fixtureVersion() == "2.0" })
        record("update.loaded-v2", updated ? "proven" : "failed", ["version": fixtureVersion() ?? "missing", "enabled": updated])
    }
}
