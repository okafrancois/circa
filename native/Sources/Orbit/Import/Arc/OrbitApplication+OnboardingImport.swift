import AppKit
import BrowserCore

/// The first-run onboarding's import step: which sources it offers and how the chosen one runs
/// after the last step, through the existing import flows.
extension OrbitApplication {
    /// The source whose import runs in place (File › Import from Arc…) rather than through the picker.
    static var onboardingArcSourceID: String { ArcBrowserImportAdapter().descriptor.id }

    /// Arc first (when its data folder exists), then the detected Chromium family, Safari, then
    /// Firefox and Zen, each with its profiles (metadata only).
    func onboardingSources(synthetic: Bool) async -> [OrbitOnboardingSource] {
        var sources: [OrbitOnboardingSource] = []
        let arguments = ProcessInfo.processInfo.arguments
        // A synthetic run looks only at its explicit Arc fixture, never at the personal folder.
        if !synthetic || arguments.contains("--arc-import-source") {
            let arc = OrbitImportLaunchOptions.source(arguments)
            if FileManager.default.fileExists(atPath: arc.appendingPathComponent("StorableSidebar.json").path) {
                let descriptor = ArcBrowserImportAdapter().descriptor
                sources.append(OrbitOnboardingSource(id: descriptor.id, name: descriptor.name,
                                                     bundleIdentifier: descriptor.bundleID, profiles: []))
            }
        }
        guard let configuration = activeSiteSessionConfiguration(),
              let choices = try? await BrowserImportCoordinator.inventory(configuration) else { return sources }
        var browsers: [OrbitOnboardingSource] = []
        for choice in choices {
            let descriptor = choice.descriptor
            let profile = choice.profile.map { OrbitOnboardingSource.Profile(directory: $0.directory, name: $0.name.isEmpty ? $0.directory : $0.name) }
            if let index = browsers.firstIndex(where: { $0.id == descriptor.id }) {
                if let profile {
                    browsers[index] = .init(id: descriptor.id, name: descriptor.name, bundleIdentifier: descriptor.bundleID,
                                            profiles: browsers[index].profiles + [profile])
                }
            } else {
                browsers.append(.init(id: descriptor.id, name: descriptor.name, bundleIdentifier: descriptor.bundleID,
                                      profiles: profile.map { [$0] } ?? []))
            }
        }
        let firefox = Set(FirefoxImportRegistry.descriptors.map(\.id))
        sources += browsers.filter { !firefox.contains($0.id) && $0.id != "safari" }
        sources += browsers.filter { $0.id == "safari" }
        sources += browsers.filter { firefox.contains($0.id) }
        return sources
    }

    /// Arc runs File › Import from Arc… (then its connections step); every other source runs
    /// Import from Another Browser… with the chosen profile instead of the picker.
    func startOnboardingImport(_ choice: BrowserOnboardingRecord.ImportChoice?) {
        guard case let .browser(sourceID, profileDirectory) = choice else { return }
        Task { @MainActor [weak self] in
            // Let the main window appear before the import's first question.
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !isPreparingToQuit else { return }
            if sourceID == Self.onboardingArcSourceID { startArcImport() }
            else { browserImport.start(application: self, preselected: .init(sourceID: sourceID, profileDirectory: profileDirectory)) }
        }
    }
}
