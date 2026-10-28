import AppKit
import BrowserCore
import UniformTypeIdentifiers

struct BrowserBookmarkTransferPreview: Equatable, Sendable {
    let links: Int
    let folders: Int
    let skipped: Int
    let profile: String
    let space: String
}

@MainActor
protocol BrowserBookmarkPanelPresenting: AnyObject {
    func chooseImport(on window: NSWindow) async -> URL?
    func chooseExport(preview: BrowserBookmarkTransferPreview, on window: NSWindow) async -> URL?
    func confirmImport(preview: BrowserBookmarkTransferPreview, on window: NSWindow) async -> Bool
    func failed(on window: NSWindow) async
    func cancel()
}

/// Both cancellation and AppKit's eventual callback finish the same continuation.
/// Source closure must not depend on AppKit delivering a sheet completion callback.
@MainActor
final class BrowserBookmarkPanelCompletion<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    @discardableResult
    func finish(_ value: Value) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}

@MainActor
final class BrowserBookmarkPanels: BrowserBookmarkPanelPresenting {
    private var cancelCurrent: (() -> Void)?

    func chooseImport(on window: NSWindow) async -> URL? {
        guard window.isVisible, window.attachedSheet == nil else { return nil }
        let panel = NSOpenPanel()
        panel.title = uiText("Import Bookmarks")
        panel.message = uiText("Choose UTF-8 bookmark HTML. Only HTTP and HTTPS links are supported; other links are counted and skipped.")
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return await choose(panel, on: window, forExport: false)
    }

    func chooseExport(preview: BrowserBookmarkTransferPreview, on window: NSWindow) async -> URL? {
        guard window.isVisible, window.attachedSheet == nil else { return nil }
        let panel = NSSavePanel()
        panel.title = uiText("Export Bookmarks")
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = uiText("Bookmarks.html")
        panel.message = uiFormat("Export %ld HTTP(S) links and %ld folders from profile “%@” (Favorites and all Spaces’ Pinned links). Today, history and other profiles are excluded. %ld unsupported links were skipped.", preview.links, preview.folders, preview.profile, preview.skipped)
        return await choose(panel, on: window, forExport: true)
    }

    private func choose(_ panel: NSSavePanel, on window: NSWindow, forExport: Bool) async -> URL? {
        guard window.isVisible, window.attachedSheet == nil else { return nil }
        let selected: URL? = await withCheckedContinuation { continuation in
            let completion = BrowserBookmarkPanelCompletion(continuation)
            cancelCurrent = { [weak self] in
                guard completion.finish(nil) else { return }
                self?.cancelCurrent = nil
                panel.cancel(nil)
            }
            panel.beginSheetModal(for: window) { [weak self] response in
                if completion.finish(response == .OK ? panel.url : nil) {
                    self?.cancelCurrent = nil
                }
            }
        }
        guard let selected else { return nil }
        return try? await Task.detached { try BrowserBookmarkFile.canonicalSelection(selected, forExport: forExport) }.value
    }

    func confirmImport(preview: BrowserBookmarkTransferPreview, on window: NSWindow) async -> Bool {
        guard window.isVisible, window.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = uiText("Import Bookmarks?")
        alert.informativeText = uiFormat("Add %ld HTTP(S) links and %ld folders to a new folder in Space “%@” of profile “%@”. Existing links stay unchanged. No pages will open. %ld unsupported links were skipped. Titles are trimmed and limited to 1,024 characters.", preview.links, preview.folders, preview.space, preview.profile, preview.skipped)
        alert.addButton(withTitle: uiText("Import"))
        alert.addButton(withTitle: uiText("Cancel"))
        return await withCheckedContinuation { continuation in
            let completion = BrowserBookmarkPanelCompletion(continuation)
            cancelCurrent = { [weak self, weak window] in
                guard completion.finish(false) else { return }
                self?.cancelCurrent = nil
                window?.endSheet(alert.window, returnCode: .cancel)
            }
            alert.beginSheetModal(for: window) { [weak self] response in
                if completion.finish(response == .alertFirstButtonReturn) { self?.cancelCurrent = nil }
            }
        }
    }

    func failed(on window: NSWindow) async {
        guard window.isVisible, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = uiText("Bookmarks Could Not Be Transferred")
        alert.informativeText = uiText("Choose a UTF-8 bookmark HTML file and an available destination. The browser’s existing saved links have not been replaced.")
        alert.addButton(withTitle: uiText("OK"))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let completion = BrowserBookmarkPanelCompletion(continuation)
            cancelCurrent = { [weak self, weak window] in
                guard completion.finish(()) else { return }
                self?.cancelCurrent = nil
                window?.endSheet(alert.window, returnCode: .cancel)
            }
            alert.beginSheetModal(for: window) { [weak self] _ in
                if completion.finish(()) { self?.cancelCurrent = nil }
            }
        }
    }

    func cancel() { cancelCurrent?() }
}
