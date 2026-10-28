import AppKit
import BrowserEngine

/// Tab-modal page dialogs of every Orbit surface (CH-ESSENTIALS): JavaScript dialogs with
/// Chromium's rules, HTTP sign-in, external application links, folder upload confirmation, the
/// unresponsive page and the crashed page. One dialog is shown per surface at a time, over that
/// surface's own document (`BrowserPageDialogView`); later ones wait their turn.
/// Owners (window tabs and Split panes, Peek, Little Orbit) call it after their ownership checks.
/// Tests and the hidden smoke observe and answer through `presentedDialog(for:)` and `respond`.
@MainActor
final class BrowserPageDialogCenter {
    static let shared = BrowserPageDialogCenter()

    private struct Entry {
        let id = UUID()
        let spec: BrowserPageDialogSpec
        weak var hostView: NSView?
        var view: BrowserPageDialogView?
        var continuation: CheckedContinuation<BrowserPageDialogResult, Never>?
    }

    private var queues: [ObjectIdentifier: [Entry]] = [:]
    private var crashed: [ObjectIdentifier: BrowserPageCrashedView] = [:]
    private(set) var rules = BrowserJavaScriptDialogRules()
    var now: () -> ContinuousClock.Instant = { .now }
    /// Smoke and test observation of every presentation.
    var onPresent: ((ObjectIdentifier, BrowserPageDialogSpec) -> Void)?

    // MARK: Observation and answers (tests, hidden smoke)

    func presentedDialog(for surface: ObjectIdentifier) -> BrowserPageDialogSpec? { queues[surface]?.first?.spec }
    func pendingCount(for surface: ObjectIdentifier) -> Int { queues[surface]?.count ?? 0 }
    func isCrashedPageShown(for surface: ObjectIdentifier) -> Bool { crashed[surface]?.superview != nil }

    /// Answers the dialog shown for `surface` as its buttons would. False when none is shown.
    @discardableResult
    func respond(for surface: ObjectIdentifier, accept: Bool, fieldValues: [String]? = nil, checkbox: Bool? = nil) -> Bool {
        guard let entry = queues[surface]?.first else { return false }
        if let view = entry.view {
            view.finish(accepted: accept, fieldValues: fieldValues, checkboxChecked: checkbox)
        } else {
            complete(surface, entry.id, BrowserPageDialogResult(accepted: accept, fieldValues: fieldValues ?? [],
                                                                checkboxChecked: checkbox ?? false))
        }
        return true
    }

    /// Reloads the crashed page shown for `surface`, as its button would.
    @discardableResult
    func reloadCrashedPage(for surface: ObjectIdentifier) -> Bool {
        guard let view = crashed[surface], view.superview != nil else { return false }
        view.performReload()
        return true
    }

    // MARK: Generic presentation

    /// Shows `spec` over `hostView` once the surface's earlier dialogs are answered.
    func present(_ spec: BrowserPageDialogSpec, on hostView: NSView, surface: ObjectIdentifier) async -> BrowserPageDialogResult {
        await withCheckedContinuation { continuation in
            var entry = Entry(spec: spec, hostView: hostView)
            entry.continuation = continuation
            queues[surface, default: []].append(entry)
            if queues[surface]?.count == 1 { show(surface) }
        }
    }

    /// Removes every dialog of `surface` (navigation reset, disposal), answering them as dismissed.
    func dismissAll(for surface: ObjectIdentifier, kinds: Set<BrowserPageDialogSpec.Kind>? = nil) {
        guard let entries = queues[surface] else { return }
        for entry in entries where kinds == nil || kinds!.contains(entry.spec.kind) {
            entry.view?.removeFromSuperview()
            complete(surface, entry.id, BrowserPageDialogResult(accepted: false), showNext: false)
        }
        if let first = queues[surface]?.first, first.view == nil { show(surface) }
    }

    private func show(_ surface: ObjectIdentifier) {
        guard let entry = queues[surface]?.first else { return }
        guard let hostView = entry.hostView else {
            complete(surface, entry.id, BrowserPageDialogResult(accepted: false))
            return
        }
        let id = entry.id
        let view = BrowserPageDialogView(spec: entry.spec) { [weak self] result in
            self?.complete(surface, id, result)
        }
        view.frame = hostView.bounds
        view.autoresizingMask = [.width, .height]
        hostView.addSubview(view, positioned: .above, relativeTo: nil)
        queues[surface]?[0].view = view
        view.claimFocus()
        onPresent?(surface, entry.spec)
    }

    private func complete(_ surface: ObjectIdentifier, _ id: UUID, _ result: BrowserPageDialogResult, showNext: Bool = true) {
        guard var entries = queues[surface], let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        queues[surface] = entries.isEmpty ? nil : entries
        entry.view?.removeFromSuperview()
        entry.continuation?.resume(returning: result)
        if showNext, index == 0, queues[surface] != nil { show(surface) }
    }

    // MARK: JavaScript dialogs

    func runJavaScriptDialog(_ dialog: BrowserJavaScriptDialog, on hostView: NSView, surface: ObjectIdentifier,
                             generation: UInt64) async -> BrowserJavaScriptDialogResponse {
        let document = BrowserJavaScriptDialogRules.Document(surface: surface, generation: generation)
        let isBeforeUnload: Bool = if case .beforeUnload = dialog.kind { true } else { false }
        guard case .show(let offersPrevention) = rules.decide(for: document, isBeforeUnload: isBeforeUnload, now: now()) else {
            return .suppressed
        }
        let spec = BrowserPageDialogText.spec(for: dialog, offersPrevention: offersPrevention)
        let result = await present(spec, on: hostView, surface: surface)
        rules.didClose(document, preventingFurther: offersPrevention && result.checkboxChecked, now: now())
        guard result.accepted else { return .cancel }
        if case .prompt = dialog.kind { return .accept(text: result.fieldValues.first ?? "") }
        return .accept(text: nil)
    }

    /// The engine dropped the surface's dialogs (`surfaceDidResetJavaScriptDialogs`), or its
    /// document changed: shown JavaScript dialogs go, the document's suppression ends.
    func resetJavaScriptDialogs(for surface: ObjectIdentifier, keepingGeneration generation: UInt64? = nil) {
        dismissAll(for: surface, kinds: [.alert, .confirm, .prompt, .beforeUnload])
        rules.reset(surface, keepingGeneration: generation)
    }

    // MARK: HTTP sign-in

    func requestCredentials(_ challenge: BrowserAuthenticationChallenge, on hostView: NSView,
                            surface: ObjectIdentifier) async -> BrowserCredential? {
        let result = await present(BrowserPageDialogText.spec(for: challenge), on: hostView, surface: surface)
        guard result.accepted, result.fieldValues.count == 2 else { return nil }
        return BrowserCredential(user: result.fieldValues[0], password: result.fieldValues[1])
    }

    // MARK: Unresponsive page

    /// Wait (true) or Exit page (false). Removed when the renderer recovers or ends.
    func askToWaitForUnresponsivePage(on hostView: NSView, surface: ObjectIdentifier) async -> Bool {
        let result = await present(BrowserPageDialogText.unresponsive(), on: hostView, surface: surface)
        return result.accepted
    }

    func dismissUnresponsive(for surface: ObjectIdentifier) {
        dismissAll(for: surface, kinds: [.unresponsive])
    }

    // MARK: Crashed page

    func showCrashedPage(on hostView: NSView, surface: ObjectIdentifier, termination: BrowserRendererTermination,
                         reload: @escaping () -> Void) {
        hideCrashedPage(for: surface)
        dismissAll(for: surface)
        let view = BrowserPageCrashedView(termination: termination.rawValue) { [weak self] in
            self?.hideCrashedPage(for: surface)
            reload()
        }
        view.frame = hostView.bounds
        view.autoresizingMask = [.width, .height]
        hostView.addSubview(view, positioned: .above, relativeTo: nil)
        crashed[surface] = view
    }

    func hideCrashedPage(for surface: ObjectIdentifier) {
        crashed.removeValue(forKey: surface)?.removeFromSuperview()
    }

    /// The surface went away: nothing of it stays shown or pending.
    func forget(_ surface: ObjectIdentifier) {
        dismissAll(for: surface)
        hideCrashedPage(for: surface)
        rules.reset(surface)
    }
}

/// Localized wording of page dialogs: Chromium's strings as packaged in
/// (the engine framework en.lproj/locale.pak, static match), Chromium's button order.
enum BrowserPageDialogText {
    /// "example.com says", with the port when it is not the scheme's default; "This page says"
    /// without a usable origin (file, opaque).
    static func javaScriptTitle(origin: String?) -> String {
        guard let display = displayOrigin(origin) else { return uiText("This page says") }
        return uiFormat("%@ says", display)
    }

    static func displayOrigin(_ origin: String?) -> String? {
        guard let origin, let url = URL(string: origin), let host = url.host, !host.isEmpty else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        let prefix = ["http", "https"].contains(scheme) ? "" : "\(scheme)://"
        return prefix + host + port
    }

    static func spec(for dialog: BrowserJavaScriptDialog, offersPrevention: Bool) -> BrowserPageDialogSpec {
        let prevention = offersPrevention ? uiText("Prevent this page from creating additional dialogs") : nil
        switch dialog.kind {
        case .alert:
            return BrowserPageDialogSpec(kind: .alert, title: javaScriptTitle(origin: dialog.origin), message: dialog.message,
                                         checkbox: prevention, primary: uiText("OK"))
        case .confirm:
            return BrowserPageDialogSpec(kind: .confirm, title: javaScriptTitle(origin: dialog.origin), message: dialog.message,
                                         checkbox: prevention, primary: uiText("OK"), secondary: uiText("Cancel"))
        case .prompt(let defaultText):
            return BrowserPageDialogSpec(kind: .prompt, title: javaScriptTitle(origin: dialog.origin), message: dialog.message,
                                         fields: [.init(label: "", initialValue: defaultText)], checkbox: prevention,
                                         primary: uiText("OK"), secondary: uiText("Cancel"))
        case .beforeUnload(let isReload):
            return BrowserPageDialogSpec(kind: .beforeUnload, title: uiText(isReload ? "Reload site?" : "Leave site?"),
                                         message: uiText("Changes you made may not be saved."),
                                         primary: uiText(isReload ? "Reload" : "Leave"), secondary: uiText("Cancel"))
        }
    }

    static func spec(for challenge: BrowserAuthenticationChallenge) -> BrowserPageDialogSpec {
        let server = challenge.port == 80 || challenge.port == 443 || challenge.port <= 0
            ? challenge.host : "\(challenge.host):\(challenge.port)"
        let message = challenge.isProxy
            ? uiFormat("The proxy %@ requires a username and password.", server)
            : uiFormat("%@ requires a username and password.", displayOrigin(challenge.origin) ?? server)
        let insecure = !challenge.isProxy && !challenge.origin.lowercased().hasPrefix("https:")
        return BrowserPageDialogSpec(kind: .authentication, title: uiText("Sign in"), message: message,
                                     note: insecure ? uiText("Your connection to this site is not private") : nil,
                                     fields: [.init(label: uiText("Username")), .init(label: uiText("Password"), isSecure: true)],
                                     primary: uiText("Sign in"), secondary: uiText("Cancel"))
    }

    static func externalProtocol(application: String, origin: String?) -> BrowserPageDialogSpec {
        let message = displayOrigin(origin).map { uiFormat("%@ wants to open this application.", $0) }
            ?? uiText("A website wants to open this application.")
        return BrowserPageDialogSpec(kind: .externalProtocol, title: uiFormat("Open %@?", application), message: message,
                                     primary: uiFormat("Open %@", application), secondary: uiText("Cancel"))
    }

    static func folderUpload(folderName: String, fileCount: Int) -> BrowserPageDialogSpec {
        let title = fileCount == 1 ? uiText("Upload 1 file to this site?") : uiFormat("Upload %ld files to this site?", fileCount)
        return BrowserPageDialogSpec(
            kind: .folderUpload, title: title,
            message: uiFormat("This will upload all files from “%@”. Only do this if you trust the site.", folderName),
            primary: uiText("Upload"), secondary: uiText("Cancel"))
    }

    static func unresponsive() -> BrowserPageDialogSpec {
        BrowserPageDialogSpec(kind: .unresponsive, title: uiText("Page Unresponsive"),
                              message: uiText("You can wait for it to become responsive or exit the page."),
                              primary: uiText("Wait"), secondary: uiText("Exit page"), escapeChoosesPrimary: true)
    }
}
