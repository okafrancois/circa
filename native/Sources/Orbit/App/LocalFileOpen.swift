import AppKit

/// Only native user input calls this boundary. It never changes attributes or origin policy.
enum LocalFileOpen {
    static func validURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.user == nil, url.password == nil, url.port == nil,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }

    @MainActor static func choose(in window: NSWindow?, completion: @escaping @MainActor ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = uiText("Open File…")
        panel.directoryURL = activeSyntheticDataGuard()?.syntheticRoot
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if let window {
            panel.beginSheetModal(for: window) { response in completion(response == .OK ? panel.urls : []) }
        } else {
            panel.begin { response in completion(response == .OK ? panel.urls : []) }
        }
    }
}

extension OrbitApplication {
    func presentOpenFile() {
        guard !isPreparingToQuit else { return }
        let destination = windows.selectedWindowID
        chooseLocalFiles(windows.selectedWindow?.window) { [weak self] urls in
            self?.openLocalFiles(urls, in: destination)
        }
    }

    /// Files always belong to the front browser window, independent of external web-link rules.
    func openLocalFiles(_ urls: [URL], in windowID: UUID? = nil) {
        let files = urls.compactMap(LocalFileOpen.validURL)
        guard !files.isEmpty, !isPreparingToQuit else { return }
        let action: (OrbitWindowController) -> Void = { [weak self] controller in
            controller.performAcceptedCommand {
                controller.openLocalFiles(files)
                self?.presentAndScheduleUpdates { self?.windowPresenter(controller, true) }
            }
        }
        if let windowID, windows.windows[windowID] != nil {
            windows.perform(in: windowID, action)
        } else { windows.perform(createIfMissing: true, action) }
    }
}
