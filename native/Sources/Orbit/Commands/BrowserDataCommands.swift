import AppKit
import BrowserCore

@MainActor
enum BrowserDataCommands {
    static func install<Window>(in registry: BrowserCommandRegistry<Window>,
                                dataRoot: @escaping () -> URL?,
                                copy: @escaping (String) -> Void = {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString($0, forType: .string)
                                },
                                reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        try! registry.registerApplication(.copyOrbitInfo) { copy(buildInformation()) }
        try! registry.registerApplication(.revealOrbitData) {
            guard let root = dataRoot() else { return }
            reveal(root)
        }
        registry.registerPrerequisite(.revealOrbitData) { _, _ in dataRoot() != nil }
    }
    /// A portable support report containing build metadata only, with no paths or browsing state.
    static func buildInformation(bundle: Bundle = .main) -> String {
        let fields = [
            "application": ProductIdentity.displayName,
            "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "system": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
