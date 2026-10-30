import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Downloads only synthetic loopback fixtures; never opens or reveals the completed files.
    func quarantineScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        environment.downloads.destinationProvider = { [runRoot] _, name in runRoot.appendingPathComponent(name) }
        let source = fixture.appendingPathComponent("source")
        for name in ["fixture.app.zip", "ordinary.txt"] {
            // Each fixture gets a fresh document so Chromium's multiple-download policy
            // does not turn this metadata check into a permission-prompt check.
            owner.openTab(url: source)
            await owner.session.waitForPendingCommands()
            guard let tab = await committed(owner, source, 5), let profile = owner.session.activeProfileID else {
                check("quarantine.source", false)
                return
            }
            let expression = "document.getElementById('\(name)').click()"
            let (started, _) = await tab.devToolsCall("Runtime.evaluate", params:
                "{\"expression\":\"\(expression)\",\"userGesture\":true}")
            check("quarantine.started." + name, started)
            let complete = await until(5) {
                environment.downloads.snapshots(profileID: profile).contains {
                    $0.suggestedFilename == name && $0.state == .complete && $0.fileAvailability == .available
                }
            }
            check("quarantine.completed." + name, complete)
            check("quarantine.final-file." + name,
                  BrowserDownloadPaths.regularFileSize(runRoot.appendingPathComponent(name)) != nil)
        }
    }
}
