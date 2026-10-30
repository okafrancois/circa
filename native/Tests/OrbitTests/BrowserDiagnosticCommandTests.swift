import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class DiagnosticServices: BrowserNativePageServices {
    var supportsTaskManager = true
    var supportsTracing = true
    var acceptsBegin = true
    var acceptsEnd = true
    var starts: [String] = []
    var ends: [URL] = []
    var taskOpens = 0
    func openTaskManager() -> Bool { taskOpens += 1; return true }
    func beginTracing(categories: String) async -> Bool { starts.append(categories); await Task.yield(); return acceptsBegin }
    func endTracing(to file: URL) async -> Bool {
        ends.append(file)
        await Task.yield()
        guard acceptsEnd else { return false }
        try! Data("{\"traceEvents\":[]}".utf8).write(to: file)
        return true
    }
    func navigationHistory() -> BrowserNavigationHistory? { nil }
    func goToEntry(index: Int) -> Bool { false }
    func securityState() -> BrowserPageSecurityState? { nil }
    func securityChanges() -> AsyncStream<BrowserPageSecurityState> { AsyncStream { $0.finish() } }
    func fullscreenChanges() -> AsyncStream<BrowserPageFullscreenChange> { AsyncStream { $0.finish() } }
    func committedURL() -> URL? { nil }
    func securityDisplay(for url: URL, scheme: BrowserSecuritySchemeDisplay) -> String? { nil }
    func mediaState() -> BrowserMediaSessionState? { nil }
    func mediaChanges() -> AsyncStream<BrowserMediaSessionState> { AsyncStream { $0.finish() } }
    func mediaAction(_ action: BrowserMediaAction, seconds: Double) -> Bool { false }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct BrowserDiagnosticCommandTests {
    @Test("Diagnostics gate on the selected live service, persistent root and private state")
    func commandGating() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        let environment = BrowserEnvironment(engine: engine)
        let router = BrowserWindowRouter(create: { id in try await environment.makeWindow(id: id) },
            present: { _, _ in }, dispose: { $0.session.close() })
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserDiagnosticCommands.install(in: registry)
        #expect(!registry.isEnabled(.openTaskManager) && !registry.isEnabled(.recordTrace))
        let id = try #require(router.newWindow())
        await router.waitForPendingCommands()
        let owner = try #require(router.windows[id])
        defer { owner.session.close(); owner.window?.close() }
        owner.openTab(url: URL(string: "https://diagnostics.invalid")!)
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface)
        let api = DiagnosticServices()
        surface.nativePageServices = api
        #expect(registry.isEnabled(.openTaskManager))
        #expect(registry.dispatch(.openTaskManager, origin: .menu))
        await owner.session.waitForPendingCommands()
        #expect(api.taskOpens == 1)
        #expect(!registry.isEnabled(.recordTrace) && !registry.isEnabled(.cancelTrace))
        engine.diagnosticRoot = FileManager.default.temporaryDirectory
        #expect(registry.isEnabled(.recordTrace))
        api.supportsTracing = false
        api.supportsTaskManager = false
        #expect(!registry.isEnabled(.recordTrace) && !registry.isEnabled(.openTaskManager))
        api.supportsTracing = true
        environment.isPrivate = true
        let privateOwner = try await environment.makeWindow()
        defer { privateOwner.session.close(); privateOwner.window?.close() }
        #expect(privateOwner.isPrivateWindow)
        surface.dispose()
        #expect(!registry.isEnabled(.openTaskManager))
        try await environment.finalize()
    }

    @Test("Record toggles to a unique file inside the profile root and reveals only completed output")
    func recordAndStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = SiteSyntheticEngine(), environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.session.close(); owner.window?.close() }
        owner.openTab(url: URL(string: "about:blank")!)
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface)
        let api = DiagnosticServices(); surface.nativePageServices = api
        var revealed: [URL] = []
        let trace = BrowserTraceRecording(reveal: { revealed.append($0) })
        trace.record(on: surface, root: root)
        #expect(trace.isBusy && !trace.canRecord(on: surface, root: root))
        await trace.operation?.value
        #expect(api.starts == [BrowserTraceRecording.categories])
        #expect(trace.canCancel(on: surface, root: root))
        let other = engine.makeSurface(profileID: ProfileID())
        other.nativePageServices = DiagnosticServices()
        #expect(!trace.canRecord(on: other, root: root))
        other.dispose()
        trace.record(on: surface, root: root)
        await trace.operation?.value
        let file = try #require(api.ends.first)
        #expect(file.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(revealed == [file] && trace.surface == nil)
        try await environment.finalize()
    }

    @Test("Cancel ends locally then removes the output without revealing it")
    func cancel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.session.close(); owner.window?.close() }
        owner.openTab(url: URL(string: "about:blank")!)
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface), api = DiagnosticServices()
        surface.nativePageServices = api
        var revealed = false
        let trace = BrowserTraceRecording(reveal: { _ in revealed = true })
        trace.record(on: surface, root: root); await trace.operation?.value
        trace.cancel(on: surface, root: root); await trace.operation?.value
        #expect(api.ends.count == 1 && !revealed && trace.surface == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try await environment.finalize()
    }

    @Test("Refused begin and end retain truthful state and allow retry without revealing output")
    func refusals() async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.session.close(); owner.window?.close() }
        owner.openTab(url: URL(string: "about:blank")!)
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface), api = DiagnosticServices()
        surface.nativePageServices = api
        let root = FileManager.default.temporaryDirectory
        var revealed = false
        let trace = BrowserTraceRecording(reveal: { _ in revealed = true })
        api.acceptsBegin = false
        trace.record(on: surface, root: root); await trace.operation?.value
        #expect(trace.surface == nil && !trace.isBusy && !trace.canCancel(on: surface, root: root))
        api.acceptsBegin = true
        trace.record(on: surface, root: root); await trace.operation?.value
        api.acceptsEnd = false
        trace.record(on: surface, root: root); await trace.operation?.value
        #expect(trace.canCancel(on: surface, root: root) && !revealed)
        api.acceptsEnd = true
        trace.cancel(on: surface, root: root); await trace.operation?.value
        #expect(trace.surface == nil && !revealed)
        try await environment.finalize()
    }
}
}
