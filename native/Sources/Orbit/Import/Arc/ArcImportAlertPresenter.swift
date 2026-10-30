import AppKit
import BrowserCore

/// Minimal native dialogs for the import (UI polish comes later): alerts for questions and results,
/// a small floating panel for progress. Shows counts only.
@MainActor
final class ArcImportAlertPresenter: ArcImportPresenting {
    private let browserImport: Bool
    private let canCancel: Bool
    init(browserImport: Bool = false, canCancel: Bool = true) { self.browserImport = browserImport; self.canCancel = canCancel }
    private var panel: NSPanel?
    private var indicator: NSProgressIndicator?
    private var label: NSTextField?
    private var onCancel: (@MainActor () -> Void)?

    func chooseSourceDirectory() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = ArcImportText.chooseMessage
        panel.prompt = ArcImportText.choosePrompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    func askToQuitArc() async -> Bool {
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = ArcImportText.quitTitle
        alert.informativeText = ArcImportText.quitMessage
        alert.addButton(withTitle: ArcImportText.checkAgain)
        alert.addButton(withTitle: ArcImportText.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showProgress(_ progress: ArcImportProgress, onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
        if panel == nil { makePanel() }
        label?.stringValue = browserImport ? BrowserImportText.phase(progress.phase) : Self.phaseText(progress.phase)
        if let fraction = progress.fraction {
            indicator?.isIndeterminate = false
            indicator?.doubleValue = fraction
        } else {
            indicator?.isIndeterminate = true
            indicator?.startAnimation(nil)
        }
        panel?.orderFront(nil)
    }

    func hideProgress() {
        panel?.orderOut(nil)
        panel = nil
        onCancel = nil
    }

    func confirmReducedImport(_ report: ArcImportReport, excluding parts: ArcImportExclusions) async -> Bool {
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = ArcImportText.reducedTitle(parts)
        alert.informativeText = ArcImportText.reducedMessage(report, parts)
        alert.addButton(withTitle: ArcImportText.importRest)
        alert.addButton(withTitle: ArcImportText.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func confirm(_ report: ArcImportReport) async -> Bool {
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = ArcImportText.confirmTitle
        alert.informativeText = ArcImportText.confirmation(report)
        alert.addButton(withTitle: ArcImportText.importButton)
        alert.addButton(withTitle: ArcImportText.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showCompletion(_ outcome: ArcImportOutcome) {
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = ArcImportText.doneTitle
        alert.informativeText = ArcImportText.completion(outcome)
        alert.addButton(withTitle: ArcImportText.ok)
        alert.runModal()
    }

    func showFailure(_ error: ArcImportError?) {
        let alert = OrbitFloatingMaterial.alert()
        alert.alertStyle = .warning
        alert.messageText = ArcImportText.failureTitle
        alert.informativeText = ArcImportText.failure(error)
        alert.addButton(withTitle: ArcImportText.ok)
        alert.runModal()
    }

    /// Offer of the daily build's first launch.
    func offerFirstRunImport() -> Bool {
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = ArcImportText.offerTitle
        alert.informativeText = ArcImportText.offerMessage
        alert.addButton(withTitle: ArcImportText.offerAccept)
        alert.addButton(withTitle: ArcImportText.offerDecline)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func phaseText(_ phase: ArcImportProgress.Phase) -> String { ArcImportText.phase(phase) }

    private func makePanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 104),
                            styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        panel.title = browserImport ? uiText("Import from Another Browser") : ArcImportText.progressTitle
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        let label = NSTextField(labelWithString: "")
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.minValue = 0
        indicator.maxValue = 1
        let cancel = NSButton(title: ArcImportText.cancel, target: self, action: #selector(cancelImport))
        cancel.isEnabled = canCancel
        let stack = NSStackView(views: [label, indicator, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = stack
        OrbitFloatingMaterial.install(in: stack, blending: .behindWindow, radius: 0)
        indicator.widthAnchor.constraint(equalToConstant: 320).isActive = true
        panel.center()
        self.panel = panel
        self.label = label
        self.indicator = indicator
    }

    @objc private func cancelImport() { onCancel?() }
}
