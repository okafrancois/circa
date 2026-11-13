import BrowserCore

extension OrbitOnboardingSource {
    /// Invented discovery metadata for confined first-run appearance captures.
    static var captureSources: [Self] {
        let descriptor = ArcBrowserImportAdapter().descriptor
        return [
            .init(id: descriptor.id, name: descriptor.name, bundleIdentifier: nil, profiles: []),
            .init(id: "chrome", name: "Chrome", bundleIdentifier: nil, profiles: []),
            .init(id: "safari", name: "Safari", bundleIdentifier: nil, profiles: []),
            .init(id: "firefox", name: "Firefox", bundleIdentifier: nil, profiles: [])
        ]
    }
}
