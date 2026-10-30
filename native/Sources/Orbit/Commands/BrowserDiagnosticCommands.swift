import AppKit
import BrowserCore
import BrowserEngine

/// A single registry owns the process-wide recording, across all browser windows/profiles.
@MainActor
final class BrowserTraceRecording {
    static let categories = "browser,toplevel,loading"
    private(set) var isBusy = false
    private(set) var surface: (any BrowserEngineSurface)?
    private var root: URL?
    private(set) var operation: Task<Void, Never>?
    private let reveal: (URL) -> Void

    init(reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        self.reveal = reveal
    }

    func canRecord(on candidate: any BrowserEngineSurface, root: URL?) -> Bool {
        guard !isBusy, !candidate.isDisposed, candidate.isReady,
              candidate.nativePageServices?.supportsTracing == true, root != nil else { return false }
        if let surface, !surface.isDisposed { return surface.profileID == candidate.profileID }
        return true
    }

    func canCancel(on candidate: any BrowserEngineSurface, root: URL?) -> Bool {
        canRecord(on: candidate, root: root) && surface?.isDisposed == false
    }

    func record(on candidate: any BrowserEngineSurface, root: URL?) {
        guard canRecord(on: candidate, root: root), let root, let api = candidate.nativePageServices else { return }
        if surface?.isDisposed == false { stop(on: candidate, keeping: true); return }
        surface = nil
        self.root = nil
        isBusy = true
        operation = Task {
            if await api.beginTracing(categories: Self.categories) {
                surface = candidate
                self.root = root
            }
            isBusy = false
        }
    }

    func cancel(on candidate: any BrowserEngineSurface, root: URL?) {
        guard canCancel(on: candidate, root: root) else { return }
        stop(on: candidate, keeping: false)
    }

    private func stop(on candidate: any BrowserEngineSurface, keeping: Bool) {
        guard let root, let api = surface?.nativePageServices else { return }
        let file = root.appendingPathComponent("trace-\(UUID().uuidString.lowercased()).json")
        isBusy = true
        operation = Task {
            if await api.endTracing(to: file) {
                surface = nil
                self.root = nil
                if keeping { reveal(file) }
                else { try? FileManager.default.removeItem(at: file) }
            }
            isBusy = false
        }
    }
}

@MainActor
enum BrowserDiagnosticCommands {
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>,
                                               recording: BrowserTraceRecording = BrowserTraceRecording()) {
        try! registry.register(.openTaskManager, validate: {
            guard let surface = $0.pageCommandSurface() else { return false }
            return !surface.isDisposed && surface.isReady && surface.nativePageServices?.supportsTaskManager == true
        }) { controller, _ in
            controller.performDocumentCommand { _ = $0.nativePageServices?.openTaskManager() }
        }
        try! registry.register(.recordTrace, validate: {
            guard let surface = $0.pageCommandSurface(), !$0.isPrivateWindow else { return false }
            return recording.canRecord(on: surface, root: $0.engine.diagnosticDataRoot(for: surface.profileID))
        }) { controller, _ in
            controller.performDocumentCommand { surface in
                recording.record(on: surface, root: controller.engine.diagnosticDataRoot(for: surface.profileID))
            }
        }
        try! registry.register(.cancelTrace, validate: {
            guard let surface = $0.pageCommandSurface(), !$0.isPrivateWindow else { return false }
            return recording.canCancel(on: surface, root: $0.engine.diagnosticDataRoot(for: surface.profileID))
        }) { controller, _ in
            controller.performDocumentCommand { surface in
                recording.cancel(on: surface, root: controller.engine.diagnosticDataRoot(for: surface.profileID))
            }
        }
    }
}
