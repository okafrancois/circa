import AppKit
import BrowserCore

/// `--arc-import-source <absolute folder>` points the importer at a copy of Arc's data folder
/// (synthetic validation data in lab runs); the default is Arc's own folder.
enum OrbitImportLaunchOptions {
    static func source(_ arguments: [String]) -> URL {
        if let index = arguments.firstIndex(of: "--arc-import-source"), arguments.indices.contains(index + 1),
           arguments[index + 1].hasPrefix("/") {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return ArcSourceSnapshot.defaultSourceRoot
    }
}

extension OrbitApplication {
    /// File › Import from Arc… and Arc › Import from Another Browser….
    func startArcImport() {
        guard !isPreparingToQuit, let environment else { NSSound.beep(); return }
        guard let target = ArcImportLiveTarget(environment: environment) else {
            // A temporary session has nowhere durable to import into.
            ArcImportAlertPresenter().showFailure(.targetUnreadable)
            return
        }
        orbitImport.onFinished = { [weak self] outcome in
            guard outcome != nil else { return }
            ArcImportFirstRunOffer.record(.accepted, at: target.location)
            // Connections (cookies, site storage) need a restart; same command, next step.
            self?.startArcSiteSessionImport(continuingArcImport: true)
        }
        if orbitImport.start(target: target) == nil { NSSound.beep() }
    }

    /// The daily build offers the import once, on a fresh session (`--offer-arc-import` forces the
    /// offer for lab validation with explicit synthetic session and source folders).
    func offerArcImportIfFirstRun(restoredWindowCount: Int) {
        guard let environment, let target = ArcImportLiveTarget(environment: environment) else { return }
        let arguments = ProcessInfo.processInfo.arguments
        let source = OrbitImportLaunchOptions.source(arguments)
        let forced = arguments.contains("--offer-arc-import")
            && !FileManager.default.fileExists(atPath: target.location.offerFile.path)
            && FileManager.default.fileExists(atPath: source.appendingPathComponent("StorableSidebar.json").path)
        guard forced || ArcImportFirstRunOffer.isEligible(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: arguments,
                                                          restoredWindowCount: restoredWindowCount, location: target.location,
                                                          orbitSource: source) else { return }
        Task { @MainActor [weak self] in
            // Let the first window appear before asking.
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !isPreparingToQuit else { return }
            let accepted = ArcImportAlertPresenter().offerFirstRunImport()
            ArcImportFirstRunOffer.record(accepted ? .accepted : .declined, at: target.location)
            if accepted { startArcImport() }
        }
    }
}
