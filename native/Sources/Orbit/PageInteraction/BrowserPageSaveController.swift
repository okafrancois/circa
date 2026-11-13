import AppKit
import BrowserEngine
import UniformTypeIdentifiers

/// Save the displayed document, never replay its URL or save a later selection's content.
@MainActor
final class BrowserPageSaveController<Engine: BrowserEngine> {
    private weak var owner: BrowserWindowController<Engine>?
    private var task: Task<Void, Never>?
    var isBusy: Bool { task != nil }
    var chooseDestination: @MainActor (NSWindow, String) async -> URL? = { window, title in
        let panel = NSSavePanel()
        panel.title = uiText("Save Page As…")
        panel.allowedContentTypes = [UTType(filenameExtension: "mhtml") ?? .data]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".mhtml"
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    init(owner: BrowserWindowController<Engine>) { self.owner = owner }

    func begin() {
        guard task == nil, let owner, owner.acceptsCommands, let window = owner.window,
              window.attachedSheet == nil, owner.engine.capabilities.contains(.pageSaving),
              let surface = owner.pageCommandSurface(), !surface.isDisposed else { return }
        let generation = surface.documentGeneration
        let title = surface.navigationState.title ?? uiText("Page")
        task = Task { [weak self, weak owner, weak surface] in
            guard let self else { return }
            defer { task = nil }
            guard let destination = await chooseDestination(window, title), let owner, let surface,
                  owner.acceptsCommands, owner.pageCommandSurface() === surface,
                  !surface.isDisposed, generation == surface.documentGeneration else { return }
            do {
                let archive = try await surface.archivePage(documentGeneration: generation)
                guard owner.acceptsCommands, owner.pageCommandSurface() === surface, !surface.isDisposed,
                      generation == surface.documentGeneration else { return }
                try archive.write(to: destination, options: .atomic)
            } catch { owner.session.onError?(error) }
        }
    }
}
