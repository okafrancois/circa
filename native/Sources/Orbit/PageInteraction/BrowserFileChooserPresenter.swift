import AppKit
import BrowserEngine
import UniformTypeIdentifiers

/// File choosers opened by pages or native engine services (CH-ESSENTIALS): `NSOpenPanel` / `NSSavePanel` as a sheet of the
/// surface's own window, as Chrome does on macOS. The page receives only what the user chose. A
/// folder upload is confirmed in the page first (Chromium's "Upload N files to this site?").
@MainActor
final class BrowserFileChooserPresenter {
    static let shared = BrowserFileChooserPresenter()

    /// Hidden smoke and tests only: answers instead of a panel (never set by the product).
    var responder: ((BrowserFileChooserRequest) async -> [URL]?)?
    /// The panel currently shown for a window, so a second request waits for no stacked sheets.
    private var busyWindows: Set<ObjectIdentifier> = []

    func run(_ request: BrowserFileChooserRequest, on hostView: NSView, surface: ObjectIdentifier) async -> [URL]? {
        let chosen: [URL]?
        if let responder {
            chosen = await responder(request)
        } else {
            guard let window = hostView.window, !busyWindows.contains(ObjectIdentifier(window)) else { return nil }
            busyWindows.insert(ObjectIdentifier(window))
            defer { busyWindows.remove(ObjectIdentifier(window)) }
            chosen = await showPanel(for: request, in: window)
        }
        guard let chosen, !chosen.isEmpty else { return nil }
        if request.mode == .openExistingFolder {
            guard chosen.count == 1, let folder = chosen.first, folder.isFileURL else { return nil }
            let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
            guard (try? canonical.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            return [canonical]
        }
        guard request.mode == .openFolder, let folder = chosen.first else { return chosen }
        let count = Self.fileCount(in: folder)
        let spec = BrowserPageDialogText.folderUpload(folderName: folder.lastPathComponent, fileCount: count)
        let confirmed = await BrowserPageDialogCenter.shared.present(spec, on: hostView, surface: surface)
        return confirmed.accepted ? [folder] : nil
    }

    /// Builds the actual native panel without displaying it; shared by presentation and tests.
    static func makePanel(for request: BrowserFileChooserRequest) -> NSSavePanel {
        let panel: NSSavePanel
        switch request.mode {
        case .save:
            let save = NSSavePanel()
            if let path = request.defaultPath {
                let url = URL(fileURLWithPath: path)
                if url.hasDirectoryPath { save.directoryURL = url } else {
                    save.directoryURL = url.deletingLastPathComponent()
                    save.nameFieldStringValue = url.lastPathComponent
                }
            }
            panel = save
        case .open, .openMultiple, .openFolder, .openExistingFolder:
            let open = NSOpenPanel()
            open.canChooseFiles = request.mode != .openFolder && request.mode != .openExistingFolder
            open.canChooseDirectories = request.mode == .openFolder || request.mode == .openExistingFolder
            open.allowsMultipleSelection = request.mode == .openMultiple
            open.resolvesAliases = true
            if request.mode == .openFolder { open.prompt = uiText("Upload") }
            if let path = request.defaultPath { open.directoryURL = URL(fileURLWithPath: path) }
            panel = open
        }
        if let title = request.title { panel.message = title }
        let types = Self.contentTypes(for: request)
        if !types.isEmpty, request.mode != .openFolder, request.mode != .openExistingFolder { panel.allowedContentTypes = types }
        return panel
    }

    private func showPanel(for request: BrowserFileChooserRequest, in window: NSWindow) async -> [URL]? {
        let panel = Self.makePanel(for: request)
        let response = await panel.beginSheetModal(for: window)
        guard response == .OK else { return nil }
        if let open = panel as? NSOpenPanel { return open.urls }
        return panel.url.map { [$0] }
    }

    /// `accept` filters as content types: MIME types (`image/*` families included), dotted
    /// extensions and the engine's expansion. Unknown entries are ignored; nothing known leaves the
    /// chooser unrestricted, as an `accept` value is only a hint.
    static func contentTypes(for request: BrowserFileChooserRequest) -> [UTType] {
        var types: [UTType] = []
        func add(_ type: UTType?) { if let type, !types.contains(type) { types.append(type) } }
        for filter in request.acceptTypes {
            switch filter {
            case "image/*": add(.image)
            case "audio/*": add(.audio)
            case "video/*": add(.movie)
            case "text/*": add(.text)
            case let value where value.hasPrefix("."): add(UTType(filenameExtension: String(value.dropFirst())))
            case let value where value.contains("/"): add(UTType(mimeType: value))
            default: break
            }
        }
        for item in request.acceptExtensions { add(UTType(filenameExtension: item)) }
        return types
    }

    /// Regular files the folder upload would send, bounded (the dialog shows the count).
    static func fileCount(in folder: URL, limit: Int = 100_000) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [], errorHandler: nil) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { count += 1 }
            if count >= limit { break }
        }
        return count
    }
}
