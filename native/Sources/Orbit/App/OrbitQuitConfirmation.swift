import AppKit

/// Quit confirmation uses a dialog and a suppression option.
enum OrbitQuitDecision { case cancel, quit, quitWithoutWarning }

@MainActor
enum OrbitQuitConfirmation {
    static func present() -> OrbitQuitDecision {
        let alert = NSAlert()
        alert.messageText = uiText("Quit Orbit?")
        alert.informativeText = uiText("Your tabs will be here when you return.")
        alert.addButton(withTitle: uiText("Quit"))
        alert.addButton(withTitle: uiText("Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = uiText("Quit, and don’t ask again")
        guard alert.runModal() == .alertFirstButtonReturn else { return .cancel }
        return alert.suppressionButton?.state == .on ? .quitWithoutWarning : .quit
    }
}
