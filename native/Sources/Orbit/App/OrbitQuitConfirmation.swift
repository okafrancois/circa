import AppKit

enum OrbitQuitDecision { case cancel, quit, quitWithoutWarning }

@MainActor
enum OrbitQuitConfirmation {
    static func present() -> OrbitQuitDecision {
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = uiText("Quit Circa?")
        alert.informativeText = uiText("Your tabs will be here when you return.")
        alert.addButton(withTitle: uiText("Quit"))
        alert.addButton(withTitle: uiText("Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = uiText("Quit, and don’t ask again")
        guard alert.runModal() == .alertFirstButtonReturn else { return .cancel }
        return alert.suppressionButton?.state == .on ? .quitWithoutWarning : .quit
    }
}
