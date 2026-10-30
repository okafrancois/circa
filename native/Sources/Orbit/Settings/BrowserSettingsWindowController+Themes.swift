import AppKit
import BrowserCore
import BrowserEngine
import SwiftUI

/// "Edit Theme Color…" in the Spaces section. The editor floats over the Settings window;
/// every browser window showing the Space follows the edit live through the store.
extension BrowserSettingsWindowController {
    func openThemeEditor(for spaceID: SpaceID, animated: Bool = true) {
        guard let window, model.acceptsActions, !model.environment.themeEditors.isFrozen, let space = model.catalog.spaces.first(where: { $0.id == spaceID }) else { return }
        guard model.environment.themeEditors.canBeginEditing(spaceID: spaceID, profileID: space.profileID) else { return }
        if let current = themeEditor {
            if current.spaceID == spaceID, !current.isClosed { current.panel?.makeKey(); return }
            current.close(animated: false)
        }
        let environment = model.environment
        let profileID = space.profileID
        let initial = space.theme ?? model.runtime.document.space(spaceID).palette.themeModel ?? BrowserSpaceThemePresets.default
        let editor = OrbitThemeEditorController(
            spaceID: spaceID, profileID: profileID, stored: space.theme, initial: initial,
            scopeDescription: space.name + " · " + (model.catalog.profiles.first(where: { $0.id == profileID })?.name ?? uiText("Profile")),
            spaceName: space.name,
            commit: { theme in
                try await environment.store.setSpaceTheme(theme, for: spaceID, profileID: profileID)
                environment.scheduleSave()
            },
            replay: { change in
                try await environment.store.applySpaceThemeChange(change)
                environment.scheduleSave()
            })
        editor.onClosed = { [weak self, weak editor] in
            guard let self else { return }
            if themeEditor === editor { themeEditor = nil }
            model.perform { [model] in await model.reload() }
        }
        environment.themeEditors.track(editor)
        themeEditor = editor
        let width = window.contentView?.bounds.width ?? OrbitThemeEditorMetrics.size.width
        editor.present(in: window, topLeft: CGPoint(x: max(0, (width - OrbitThemeEditorMetrics.size.width) / 2), y: 40),
                       animated: animated)
    }
}

/// Small preview of a Space theme's light variant in the Spaces section. Decorative.
struct BrowserSettingsThemeSwatch: View {
    let theme: BrowserSpaceTheme?

    var body: some View {
        BrowserSettingsThemeGradient(theme: theme)
            .clipShape(Circle())
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

/// Uses the stored angle and stop locations at the actual preview aspect ratio.
struct BrowserSettingsThemeGradient: View {
    let theme: BrowserSpaceTheme?
    var body: some View {
        GeometryReader { geometry in
            let gradient = (theme ?? BrowserSpaceThemePresets.default).light
            let angle = gradient.angleDegrees * .pi / 180
            let width = max(1, geometry.size.width), height = max(1, geometry.size.height)
            let length = abs(width * cos(angle)) + abs(height * sin(angle))
            let dx = cos(angle) * length / width / 2, dy = sin(angle) * length / height / 2
            LinearGradient(stops: gradient.stops.enumerated().map { index, color in
                .init(color: Color(nsColor: OrbitSpaceThemes.color(color)),
                      location: gradient.locations?[index] ?? Double(index) / Double(max(1, gradient.stops.count - 1)))
            }, startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy), endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
        }
    }
}
