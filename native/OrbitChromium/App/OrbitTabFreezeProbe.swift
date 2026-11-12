import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Foundation

/// Confined freeze measurements on loopback fixtures; no personal browsing state is accepted.
@MainActor
enum OrbitTabFreezeProbe {
    static let bundleID = "lab.orbit.orbit.perf-tab-freeze"
    static func run(_ owner: OrbitWindowController, command: [String: String], root: URL) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true else { return ["refused": true] }
        switch command["step"] {
        case "fixture":
            guard let text = command["url"], let url = URL(string: text), url.host == "127.0.0.1", url.scheme == "http" else { return ["refused": true] }
            owner.resources.coordinator.budget = nil
            for tab in owner.session.snapshot?.tabs ?? [] { owner.session.closeOccurrence(tab.occurrenceID) }
            await owner.session.waitForPendingCommands()
            for index in 0..<15 {
                owner.session.openTab(url: url.appendingPathComponent(String(index)))
                await owner.session.waitForPendingCommands()
                for _ in 0..<100 {
                    if let surface = owner.session.selectedSurface, surface.isReady, !surface.navigationState.isLoading { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            owner.tabSuspension.close()
            owner.tabSuspension.selectionDidChange()
            owner.window?.orderOut(nil)
        case "freeze":
            _ = await owner.tabSuspension.sweep(now: ProcessInfo.processInfo.systemUptime + 330)
            try? await Task.sleep(for: .milliseconds(500))
        case "show":
            owner.window?.orderFrontRegardless()
        case "hide":
            owner.window?.orderOut(nil)
        case "return":
            guard let surface = owner.session.ownedSurfaces.first(where: { $0.pagePerformance?.lifecycle()?.state == .frozen }),
                  let id = owner.session.occurrenceID(for: surface) else { return ["noFrozenTab": true] }
            owner.session.selectOccurrence(id)
            await owner.session.waitForPendingCommands()
            try? await Task.sleep(for: .milliseconds(300))
            let reply = await surface.devToolsCall("Runtime.evaluate", params: #"{"expression":"({ticks:window.ticks,form:document.querySelector('input').value})","returnByValue":true}"#)
            let image = try? await surface.captureSnapshot(.init(width: 900, documentGeneration: surface.documentGeneration))
            if let image { try? NSBitmapImageRep(cgImage: image.image).representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("returned.png")) }
            return ["running": surface.pagePerformance?.lifecycle()?.state == .running, "script": String(data: reply.1, encoding: .utf8) ?? "", "captured": image != nil]
        default: break
        }
        return ["window": owner.window?.windowNumber ?? 0, "tabs": owner.session.ownedSurfaces.count, "pages": owner.session.ownedSurfaces.map { surface in
            let state = surface.pagePerformance?.lifecycle()
            return ["state": state?.state.rawValue ?? -1, "mask": String(state?.cannotFreezeMask ?? .max), "pid": state?.rendererPID ?? 0] as [String: Any]
        }]
    }
}
