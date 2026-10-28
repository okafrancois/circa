import Foundation

@MainActor protocol BrowserEngineSurface: AnyObject {}
@MainActor protocol BrowserExtensionManagement: AnyObject {
    func openManagement(on surface: any BrowserEngineSurface) throws
}
enum BrowserEngineError: Error { case unsupportedOperation }
enum Persistence { case persistent, ephemeral }
enum Mode { case hosted, alloy }
final class Window {}
@MainActor final class View { var window: Window? = Window() }
@MainActor final class Registration {
    var token: UInt64 = 3
    var isClosed = false
    var window: Window?
}
@MainActor final class Runtime {
    var ready = true
    func isProfileReady(_ token: UInt64) -> Bool { ready && token == 2 }
}
@MainActor protocol BrowserExtensionHost: AnyObject {}
@MainActor final class ChromiumExtensionHost: BrowserExtensionHost {
    init(engine: ChromiumBrowserEngine) {}
}
@MainActor final class ChromiumBrowserEngine {
    var isShutDown = false
    var persistence = Persistence.persistent
    var surfaceMode = Mode.hosted
    var refusedProfiles = Set<Int>()
    var shellWindows: [Int: Registration] = [:]
    let runtime = Runtime()
    func profileToken(for id: Int) -> UInt64 { 2 }
    // Exact production service properties are appended by the runner.
    /* PROPERTIES */
}
@MainActor final class ChromiumSurface: BrowserEngineSurface {
    weak var engine: ChromiumBrowserEngine?
    var isDisposed = false, isReady = true
    var hostedWindowToken: UInt64 = 3
    var profileID = 1
    var token: UInt64 = 1
    let hostView = View()
}
@MainActor var version = 3
@MainActor var service = true
@MainActor var calls: [UInt64] = []
@MainActor func ACRExtensionManagementAvailable() -> Int32 { service && version >= 3 ? 1 : 0 }
@MainActor func ACRExtensionsAvailable() -> Int32 { service && version >= 4 ? 1 : 0 }
@MainActor func ACROpenExtensionManager(_ token: UInt64) -> Int32 { calls.append(token); return 1 }
// EXT-OUTCOME-R2 dependency stand-in: the adapter also routes details/shortcuts pages.
@MainActor func ACROpenExtensionManagerPage(_ token: UInt64, _ page: Int32, _ id: UnsafePointer<CChar>?) -> Int32 { calls.append(token); return 1 }
/* ADAPTER */
@main struct Test {
    @MainActor static func main() throws {
        let engine = ChromiumBrowserEngine(), surface = ChromiumSurface(), registration = Registration()
        surface.engine = engine
        registration.window = surface.hostView.window
        engine.shellWindows[1] = registration
        precondition(engine.extensions == nil)
        let manager = engine.extensionManagement!
        try manager.openManagement(on: surface)
        precondition(calls == [1])
        func refused() {
            let before = calls.count
            do { try manager.openManagement(on: surface); preconditionFailure("unexpected authority") }
            catch {}
            precondition(calls.count == before)
        }
        surface.isReady = false; refused(); surface.isReady = true
        surface.isDisposed = true; refused(); surface.isDisposed = false
        surface.hostedWindowToken = 9; refused(); surface.hostedWindowToken = 3
        surface.hostView.window = nil; refused(); surface.hostView.window = registration.window
        registration.isClosed = true; refused(); registration.isClosed = false
        registration.window = Window(); refused(); registration.window = surface.hostView.window
        engine.shellWindows = [:]; refused(); engine.shellWindows[1] = registration
        engine.runtime.ready = false; refused(); engine.runtime.ready = true
        engine.refusedProfiles.insert(1); refused(); engine.refusedProfiles = []
        let foreignEngine = ChromiumBrowserEngine(); surface.engine = foreignEngine; refused(); surface.engine = engine
        engine.persistence = .ephemeral; refused(); precondition(engine.extensionManagement == nil); engine.persistence = .persistent
        engine.surfaceMode = .alloy; refused(); precondition(engine.extensionManagement == nil); engine.surfaceMode = .hosted
        engine.isShutDown = true; refused(); precondition(engine.extensionManagement == nil); engine.isShutDown = false
        service = false; refused(); precondition(engine.extensionManagement == nil); service = true
        version = 2; refused(); precondition(engine.extensionManagement == nil)
        version = 4
        precondition(engine.extensions != nil && engine.extensionManagement != nil)
        try manager.openManagement(on: surface)
        precondition(calls == [1, 1])
        print("PASS actual Swift service properties/manager adapter: v3/v4, missing, foreign, closed, refused and stale states")
    }
}
