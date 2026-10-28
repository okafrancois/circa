import AppKit
import OrbitChromiumBridge
import BrowserCore
import BrowserEngine
import BrowserShell
import ChromiumEngine
import Foundation

/// Result ledger: one entry per checked behaviour, status proven / failed / partial / not-attempted.
@MainActor
final class LabLedger {
    private(set) var entries: [[String: Any]] = []
    private let events: FileHandle?
    private let start = Date()

    init(root: URL) {
        let path = root.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
        events = try? FileHandle(forWritingTo: path)
    }

    func event(_ name: String, _ fields: [String: String] = [:]) {
        var line = fields
        line["event"] = name
        line["t"] = String(format: "%.3f", Date().timeIntervalSince(start))
        if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
            events?.write(data + Data("\n".utf8))
        }
    }

    func record(_ id: String, _ status: String, _ evidence: [String: Any] = [:]) {
        var entry = evidence
        entry["id"] = id
        entry["status"] = status
        entries.append(entry)
        event("result", ["id": id, "status": status])
    }

    func check(_ id: String, _ condition: Bool, _ evidence: [String: Any] = [:]) {
        record(id, condition ? "proven" : "failed", evidence)
    }

    func write(to url: URL, extra: [String: Any]) {
        var document = extra
        document["results"] = entries
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

/// Bridge bookkeeping snapshot (laboratory introspection).
@MainActor
func bridgeDiagnostics() -> [String: Int] {
    var diagnostics = ACRDiagnostics()
    diagnostics.struct_size = UInt32(MemoryLayout<ACRDiagnostics>.size)
    guard ACRGetDiagnostics(&diagnostics) == 1 else { return [:] }
    return ["hosts": Int(diagnostics.hosts), "pendingCreations": Int(diagnostics.pending_creations),
            "pendingPopups": Int(diagnostics.pending_popups), "abandonedPopups": Int(diagnostics.abandoned_popups),
            "pageCloseRequests": Int(diagnostics.page_close_requests), "policies": Int(diagnostics.policies),
            "permissions": Int(diagnostics.permissions), "destinations": Int(diagnostics.destinations),
            "downloads": Int(diagnostics.downloads), "abortedCreations": Int(diagnostics.aborted_creations),
            "quitStalls": Int(diagnostics.quit_stalls)]
}

@MainActor
func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(40))
    }
    return condition()
}

@MainActor
func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

/// Records every engine-to-shell callback of the surfaces it owns.
@MainActor
final class RecorderDelegate: BrowserEngineSurfaceDelegate {
    typealias Surface = ChromiumSurface

    struct Counts { var starts = 0, commits = 0, finishes = 0, failures = 0 }
    var counts: [ObjectIdentifier: Counts] = [:]
    var acceptNewSurfaces = true
    var newSurfaceRequests: [BrowserNewSurfaceRequest] = []
    var createdSurfaces: [ChromiumSurface] = []
    var closeRequests: [ObjectIdentifier] = []
    var permissionRequests: [BrowserPermissionRequest] = []
    var permissionDecision: BrowserPermissionDecision = .deny
    /// Asynchronous answer to a permission request; nil answers `permissionDecision` at once.
    var permissionHandler: ((ChromiumSurface, BrowserPermissionRequest) async -> BrowserPermissionDecision)?
    var asyncPolicyCalls = 0  // action policy questions (synchronous decisions since CONTRACT-R1)
    var onDownload: ((ChromiumSurface, any BrowserEngineDownload) -> Void)?
    var onNewSurface: ((ChromiumSurface) -> Void)?
    let ledger: LabLedger

    init(ledger: LabLedger) { self.ledger = ledger }

    func count(_ surface: ChromiumSurface) -> Counts { counts[ObjectIdentifier(surface)] ?? Counts() }

    func surfaceDidStartNavigation(_ surface: ChromiumSurface) { counts[ObjectIdentifier(surface), default: Counts()].starts += 1 }
    func surfaceDidCommitNavigation(_ surface: ChromiumSurface) { counts[ObjectIdentifier(surface), default: Counts()].commits += 1 }
    func surfaceDidFinishNavigation(_ surface: ChromiumSurface) { counts[ObjectIdentifier(surface), default: Counts()].finishes += 1 }
    func surfaceDidFailNavigation(_ surface: ChromiumSurface) { counts[ObjectIdentifier(surface), default: Counts()].failures += 1 }

    /// Synchronous answer to OnBeforeBrowse; nil allows.
    var actionPolicy: ((BrowserNavigationAction) -> BrowserNavigationActionPolicy)?
    var suspensionOffered: [Bool] = []
    var responsePolicyCalls = 0

    func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        asyncPolicyCalls += 1
        suspensionOffered.append(decision.canSuspend)
        decision.decide(actionPolicy?(action) ?? .allow)
    }

    func surface(_ surface: ChromiumSurface, decidePolicyFor response: BrowserNavigationResponse,
                 decision: BrowserPolicyDecision<BrowserNavigationResponsePolicy>) {
        responsePolicyCalls += 1
        decision.decide(.allow)
    }

    func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> ChromiumSurface) -> ChromiumSurface? {
        newSurfaceRequests.append(request)
        ledger.event("new-surface-request", ["url": request.url?.absoluteString ?? "",
                                             "modifiers": String(request.modifiers.rawValue)])
        guard acceptNewSurfaces else { return nil }
        let created = make()
        createdSurfaces.append(created)
        onNewSurface?(created)
        return created
    }

    func surfaceDidRequestClose(_ surface: ChromiumSurface) { closeRequests.append(ObjectIdentifier(surface)) }

    func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) {
        if let onDownload { onDownload(surface, download) } else { download.cancel() }
    }

    func surface(_ surface: ChromiumSurface, requestsPermission request: BrowserPermissionRequest) async -> BrowserPermissionDecision {
        permissionRequests.append(request)
        if let permissionHandler { return await permissionHandler(surface, request) }
        return permissionDecision
    }
}

/// A hidden shell window: never ordered in, never key, never main.
@MainActor
func makeHiddenWindow(_ title: String) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = title
    HiddenGuard.shared.registerLabWindow(window)
    return window
}

@MainActor
func place(_ surface: ChromiumSurface, in container: NSView) {
    surface.hostView.removeFromSuperview()
    surface.hostView.frame = container.bounds
    surface.hostView.autoresizingMask = [.width, .height]
    container.addSubview(surface.hostView)
}

/// DevTools `Runtime.evaluate`, returning the JSON value. Native-side observation only.
@MainActor
func evaluate(_ surface: ChromiumSurface, _ expression: String, gesture: Bool = false) async -> Any? {
    let params: [String: Any] = ["expression": expression, "returnByValue": true, "awaitPromise": true,
                                 "userGesture": gesture]
    guard let data = try? JSONSerialization.data(withJSONObject: params),
          let json = String(data: data, encoding: .utf8) else { return nil }
    let (success, payload) = await surface.devToolsCall("Runtime.evaluate", params: json)
    guard success, let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
          let result = object["result"] as? [String: Any] else { return nil }
    return result["value"] ?? NSNull()
}
