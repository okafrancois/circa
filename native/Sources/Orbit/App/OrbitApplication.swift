import AppKit
import QuartzCore
import BrowserCore
import BrowserEngine
import BrowserShell

/// Application lifetime: startup, window routing, termination. Engine-independent; the engine
/// comes from `makeActiveEngine()` in the composition root.
@main
@MainActor
final class OrbitApplication: NSObject, NSApplicationDelegate {
    lazy var scripting: BrowserScriptingController = {
        let controller = BrowserScriptingController()
        configureScripting(controller)
        return controller
    }()

    var chooseLocalFiles: @MainActor (NSWindow?, @escaping @MainActor ([URL]) -> Void) -> Void = LocalFileOpen.choose
    private(set) var environment: OrbitEnvironment?
    private let inactiveUpdater = OrbitUpdater()
    var updater: OrbitUpdater { environment?.settings.updater ?? inactiveUpdater }
    private var scheduledUpdater = false
    var afterWindowCommit: (@escaping @MainActor () -> Void) -> Void = { completion in
        CATransaction.setCompletionBlock { Task { @MainActor in completion() } }
    }
    var onUpdaterStart: (() -> Void)?

    /// Called for normal and quick windows, including cold external-URL launches.
    func presentAndScheduleUpdates(_ present: () -> Void) {
        guard !scheduledUpdater else { present(); return }
        scheduledUpdater = true
        CATransaction.begin()
        present()
        afterWindowCommit { [weak self] in
            guard let self else { return }
            onUpdaterStart?()
            configureIdleUpdates()
            updater.start(synthetic: activeSyntheticDataGuard() != nil)
            BrowserPerformance.mark(.updaterStarted)
        }
        CATransaction.commit()
    }

    var quitPreferenceSave: Task<Void, Error>?
    var confirmQuit: @MainActor () -> OrbitQuitDecision = OrbitQuitConfirmation.present
    var confirmDownloadQuit: @MainActor () -> Bool = {
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = uiText("Downloads Are Still in Progress")
        alert.informativeText = uiText("Quitting will cancel your downloads.")
        alert.addButton(withTitle: uiText("Continue Downloads"))
        alert.addButton(withTitle: uiText("Quit and Cancel Downloads"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    func waitForScriptingStartup() async { await startupTask?.value }

    private var startupTask: Task<Void, Never>?
    private(set) var isStartingUp = false
    private var externalURLStartupComplete = false
    private var pendingExternalURLs: [URL] = []
    private(set) var isPreparingToQuit = false
    private var didPresentSaveError = false
    var isImportingSiteSessions = false
    var pendingSiteSessionRequest: ArcSiteSessionRequest?
    var wantsSiteSessionRelaunch = false
    var pendingBrowserImport: BrowserImportOfflineJob?
    /// First-run onboarding of this launch; main windows are held until it hands off.
    var onboarding: OrbitOnboardingWindowController?
    var heldOnboardingWindows: [OrbitWindowController] = []
    var onOnboardingFinished: ((BrowserOnboardingRecord) -> Void)?
    lazy var browserImport = BrowserImportCoordinator()
    var settingsWindow: BrowserSettingsWindowController<ActiveEngine>?
    lazy var commands = makeCommandSystem()
    lazy var orbitImport = ArcImportCoordinator(presenter: ArcImportAlertPresenter(),
                                              defaultSource: OrbitImportLaunchOptions.source(ProcessInfo.processInfo.arguments))
    /// The key window as command routing sees it. Hidden event-level tests inject their own
    /// window: an application that is never activated has no AppKit key window.
    let commandKeyWindow: () -> NSWindow?
    var tearOffRequests: [UUID: SidebarTearOffRequest] = [:]
    var inheritedContexts: [UUID: Task<BrowserContext?, Never>] = [:]
    var inheritedWindowProfiles: [UUID: ProfileID] = [:]
    var privateWindowFactory: BrowserPrivateDomainFactory<ActiveEngine>?
    var privateWindows: [UUID: OrbitPrivateWindow] = [:]
    var privateWindowCommands: Task<Void, Never>?
    var privateWindowClosures: [UUID: Task<Void, Never>] = [:]
    /// Windows opened for a rescued document, in a Space of its profile.
    private var rescueSpaces: [UUID: SpaceID] = [:]
    var quickWindowCommands: Task<Void, Never>?
    var quickWindowRoutingFailure: () -> Void = { NSSound.beep() }
    var quickWindowOpenRequests: [BrowserQuickWindowOpenRequest] = []
    var unroutedQuickWindowURLs: [URL] { quickWindowOpenRequests.compactMap(\.url) }
    var provisionalQuickWindowWindows: Set<UUID> = []
    var quickWindowPromotionWindowPrepared: ((OrbitWindowController) -> Void)?
    var quickWindowDestinationSpaces: [UUID: SpaceID] = [:]
    var quickWindowPresenter: (BrowserQuickWindowWindowController<ActiveEngine>) -> Void = { controller in
        guard NSApp.activationPolicy() != .prohibited else { return }
        controller.window?.deminiaturize(nil)
        controller.showWindow(nil)
        controller.focusInitialContent()
        NSApp.activate()
    }
    var windowPresenter: (OrbitWindowController, Bool) -> Void = { controller, activate in
        if activeSyntheticDataGuard() != nil, ProcessInfo.processInfo.arguments.contains("--scripting-test-offscreen") {
            controller.window?.setFrameOrigin(NSPoint(x: -8000, y: -8000))
            controller.window?.orderBack(nil)
            return
        }
        if activate { controller.showWindow(nil) }
        else { controller.window?.orderFront(nil) }
        if ProcessInfo.processInfo.arguments.contains("--window-diagnostics"), let window = controller.window {
            print("orbit-window event=present visible=\(window.isVisible) key=\(window.isKeyWindow) active=\(NSApp.isActive) number=\(window.windowNumber) width=\(Int(window.frame.width)) height=\(Int(window.frame.height))")
            fflush(stdout)
        }
    }

    override init() {
        commandKeyWindow = { NSApp?.keyWindow }
        super.init()
    }

    /// Allows hidden integration tests to use the actual application orchestration with an
    /// explicit temporary environment, without launching an application or presenting windows.
    init(environment: OrbitEnvironment, externalURLStartupComplete: Bool = true,
         commandKeyWindow: @escaping () -> NSWindow? = { NSApp?.keyWindow },
         windowPresenter: @escaping (OrbitWindowController, Bool) -> Void) {
        self.environment = environment
        self.commandKeyWindow = commandKeyWindow
        self.externalURLStartupComplete = externalURLStartupComplete
        self.windowPresenter = windowPresenter
        super.init()
    }

    private(set) lazy var windows: BrowserWindowRouter<OrbitWindowController> = BrowserWindowRouter(
        create: { [weak self] id in
            guard let self, let environment = self.privateWindows[id]?.environment ?? self.environment else { throw CancellationError() }
            defer { self.inheritedWindowProfiles[id] = nil }
            let spaceID: SpaceID?
            let tearOff = self.tearOffRequests.removeValue(forKey: id)
            let opensInitialTab = tearOff == nil && self.quickWindowDestinationSpaces[id] == nil && !environment.isPrivate
            if let tearOff {
                spaceID = tearOff.payload.spaceID
            } else if let contextTask = self.inheritedContexts.removeValue(forKey: id) {
                guard let context = await contextTask.value else { throw CancellationError() }
                spaceID = context.spaceID
            } else if let littleSpace = self.quickWindowDestinationSpaces.removeValue(forKey: id) {
                spaceID = littleSpace
            } else if let rescueSpace = self.rescueSpaces.removeValue(forKey: id) {
                spaceID = rescueSpace
            } else {
                spaceID = nil
            }
            let controller = try await environment.makeWindow(id: id, spaceID: spaceID, opensInitialTab: opensInitialTab, standalone: tearOff != nil, onInput: { [weak self] action in
                guard let self, !isPreparingToQuit else { return }
                windows.perform(in: id) { controller in controller.performAcceptedCommand { action(controller) } }
            }, onClose: { [weak self] in
                self?.windows.remove(id)
                self?.inheritedContexts.removeValue(forKey: id)
                self?.releasePrivateWindow(id)
            }, onActivate: { [weak self] in self?.windows.activate(id) })
            controller.onTearOffTab = { [weak self, weak controller] payload, point in
                guard let controller else { return }
                self?.tearOff(payload, from: controller, at: point)
            }
            if let tearOff {
                await tearOff.waitForPresentation()
                guard !Task.isCancelled, let source = tearOff.source, source.acceptsCommands,
                      let tab = tearOff.payload.nodes.first?.tabID,
                      let surface = source.liveSidebarSurface(of: tab),
                      let move = source.moveSurface(surface, to: controller, activate: true, replacingExisting: true),
                      await move.value != nil else { controller.window?.close(); throw CancellationError() }
                controller.window?.setFrame(tearOff.placement.frame, display: false)
                controller.windowedFrame = tearOff.placement.frame
                controller.windowShell.setSidebarWidth(tearOff.sidebarWidth)
                controller.restoresFullScreen = tearOff.placement.entersFullScreen
            }
            controller.favorites.bind(to: self.commands.registry)
            controller.palette.registry = self.commands.registry
            controller.sidebar.spaceShortcutLabel = { [weak registry = self.commands.registry] index in
                guard let registry else { return nil }
                return BrowserSpaceCommands.shortcutLabel(at: index, definitions: registry.definitions)
            }
            if self.isPreparingToQuit { controller.freezeCommandsForTermination() }
            return controller
        },
        present: { [weak self] controller, activate in
            guard let self, !provisionalQuickWindowWindows.contains(controller.id) else { return }
            if holdsWindowForOnboarding(controller) { return }
            presentAndScheduleUpdates {
                windowPresenter(controller, activate)
                if activate, controller.session.snapshot?.isStandalone == true { controller.focusSelectedDocument() }
                if controller.restoresFullScreen, let window = controller.window, !window.styleMask.contains(.fullScreen) {
                    controller.restoresFullScreen = false
                    controller.toggleNativeFullScreen(window)
                }
            }
            BrowserPerformance.mark(.windowPresented)
            if BrowserPerformance.enabled, controller.window?.isVisible == true {
                controller.window?.displayIfNeeded()
                CATransaction.flush()
                BrowserPerformance.mark(.windowCommitted)
                if !controller.session.hasPendingCommands, controller.window?.firstResponder != nil {
                    BrowserPerformance.mark(.windowInteractive)
                }
            }
        },
        // Only termination disposes routed windows: the model is preserved for restoration.
        dispose: { controller in
            controller.retireForTermination()
            controller.window?.close()
        }
    )

    /// The engine's launcher owns process entry: a Chromium build must start its runtime
    /// before `NSApplication.shared` exists.
    static func main() {
        BrowserPerformance.mark(.main)
        if let result = BrowserSyncLaunchVerification.run(arguments: CommandLine.arguments) { exit(result) }
        OrbitLauncher.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        OrbitAppIconController.reapplyForCurrentApplication()
        BrowserPerformance.mark(.applicationLaunched)
        BrowserPerformance.mark(.menusBegin)
        installMenus()
        BrowserPerformance.mark(.menusReady)
        windows.onError = { _ in
            if ProcessInfo.processInfo.arguments.contains("--window-diagnostics") {
                print("orbit-window event=route-error")
                fflush(stdout)
            }
            NSSound.beep()
        }
        isStartingUp = true
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer { isStartingUp = false }
            do {
                let configuration = try PreviewLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
                environment = try await OrbitEnvironment.open(engine: makeActiveEngine(), sessionFile: configuration.sessionFile)
            } catch {
                let alert = OrbitFloatingMaterial.alert()
                alert.messageText = uiText("Could Not Restore the Local Session")
                if (error as? ArcImportError) == .restoreJournalUnreadable {
                    alert.informativeText = uiText("A restore of this session was interrupted and its journal cannot be read. Circa did not open the session and kept every file. Run “orbit-import recover-restore”, or open a temporary session meanwhile.")
                } else if (error as? ArcImportError) == .targetInUse {
                    alert.informativeText = uiText("An Circa import or restore is using this session. Open Circa again when it finishes; meanwhile you can open a temporary session.")
                } else {
                    alert.informativeText = uiText("Your existing session file is kept. You can open a temporary session without changing it.")
                }
                alert.addButton(withTitle: uiText("Temporary Session"))
                alert.addButton(withTitle: uiText("Quit"))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    NSApp.terminate(nil)
                    return
                }
                environment = OrbitEnvironment(engine: makeActiveEngine())
            }
            BrowserPerformance.mark(.environmentReady)
            if let environment {
                commands.registry.useShortcutPreferences(environment.shortcutPreferences)
                environment.onReopenClosedWindow = { [weak self] id in self?.windows.newWindow(id: id.rawValue) }
            }
            environment?.onPersistenceError = { [weak self] error in self?.presentSaveError(error) }
            environment?.onRescueNeedsWindow = { [weak self] profileID in self?.openRescueWindow(for: profileID) }
            environment?.onRescueSplitNeedsWindow = { [weak self] profileID, spaceID in
                self?.openRescueWindow(for: profileID, preferredSpaceID: spaceID)
            }
            environment?.onPersistenceSuccess = { [weak self] in self?.didPresentSaveError = false }
            let restoredWindowCount = environment?.restoredWindowIDs.count ?? 0
            await prepareOnboarding()
            if let ids = environment?.restoredWindowIDs, !ids.isEmpty {
                for id in ids { windows.newWindow(id: id.rawValue) }
            } else if pendingExternalURLs.isEmpty || environment?.settings.document.opensExternalLinksInQuickWindow != true {
                windows.newWindow()
            }
            do { try await environment?.restoreQuickWindowsAfterUpdate(present: quickWindowPresenter) }
            catch { presentSaveError(error) }
            finishExternalURLStartup()
            presentSiteSessionImportOutcome()
            presentBrowserImportResult()
            if let onboarding { onboarding.present() }
            else { offerArcImportIfFirstRun(restoredWindowCount: restoredWindowCount) }
        }
    }

    /// LaunchServices delivers cold-launch URL events before or during asynchronous restoration.
    /// Retain their order until restoration has scheduled its windows in the router.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingExternalURLs.append(contentsOf: urls.compactMap(ExternalURLResolver.resolve))
        drainPendingExternalURLs()
    }

    func finishExternalURLStartup() {
        externalURLStartupComplete = true
        drainPendingExternalURLs()
    }

    private func drainPendingExternalURLs() {
        guard externalURLStartupComplete, !isPreparingToQuit, onboarding == nil else { return }
        let urls = pendingExternalURLs
        pendingExternalURLs.removeAll()
        routeExternalURLs(urls)
    }

    private func routeExternalURLs(_ urls: [URL]) {
        guard !urls.isEmpty, let environment, !isPreparingToQuit else { return }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { openLocalFiles(files) }
        let urls = urls.filter { !$0.isFileURL }
        guard !urls.isEmpty else { return }
        selectNormalWindowForExternalRequest()
        let routing = environment.settings.document.linkRouting
        if !routing.rules.isEmpty || urls.contains(where: BrowserMeetingLink.matches)
            || { if case .space = routing.defaultDestination { return true }; return false }() {
            routeConfiguredExternalURLs(urls, routing: routing)
            return
        }
        let profileID = windows.selectedWindow?.session.activeProfileID
            ?? windows.selectedWindowID.flatMap { inheritedWindowProfiles[$0] }
        let requests = urls.map {
            BrowserQuickWindowOpenRequest(url: $0, profileID: profileID,
                opensInQuickWindow: environment.settings.document.opensExternalLinksInQuickWindow, isExternalOpen: true)
        }
        quickWindowOpenRequests.append(contentsOf: requests)
        if environment.settings.document.opensExternalLinksInQuickWindow, windows.selectedWindowID == nil {
            for request in requests { scheduleQuickWindowRequest(request) }
            return
        }
        // A failed pending window must report abandonment. Keep every accepted URL until the
        // ordered session confirms delivery, including when its captured source closes.
        windows.perform(createIfMissing: !environment.settings.document.opensExternalLinksInQuickWindow,
            onAbandon: { [weak self] in
                for request in requests { self?.retainQuickWindowRequest(request) }
            }) { [weak self] controller in
                guard let self else { return }
                controller.performAcceptedCommand {
                    if requests.first?.opensInQuickWindow == true {
                        for request in requests { scheduleQuickWindowRequest(request, source: controller) }
                    } else {
                        let context = controller.session.captureContextInCommandOrder()
                        controller.hideLibrary()
                        let deliveries = requests.map { request in
                            controller.session.openTabForDelivery(url: request.url!)
                        }
                        presentAndScheduleUpdates { windowPresenter(controller, true) }
                        if NSApp.activationPolicy() != .prohibited { NSApp.activate() }
                        enqueueQuickWindowCommand { [weak self] in
                            guard let self else { return }
                            let captured = await context.value
                            for (request, delivery) in zip(requests, deliveries) {
                                if let captured {
                                    request.profileID = captured.profileID
                                    request.spaceID = captured.spaceID
                                }
                                if let tab = await delivery.value {
                                    request.spaceID = tab.spaceID
                                    confirmQuickWindowRequest(request)
                                } else { retainQuickWindowRequest(request) }
                            }
                        }
                    }
                }
            }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToQuit else { return .terminateLater }
        defer { if !isPreparingToQuit { updater.cancelAutomaticRelaunch(); discardStagedPasswordImport(); pendingSiteSessionRequest = nil; pendingBrowserImport = nil } }
        guard updater.permitsAutomaticTermination else {
            updater.cancelAutomaticRelaunch()
            return .terminateCancel
        }
        guard settingsWindow?.model.isRequestingDefaultBrowser != true else { return .terminateCancel }
        guard updater.isRestartingForUpdate || confirmQuitIfNeeded() else { return .terminateCancel }
        if environment?.downloads.hasActiveTransfers == true {
            guard confirmDownloadQuit() else { return .terminateCancel }
        }
        isPreparingToQuit = true
        for controller in windows.windows.values { controller.freezeCommandsForTermination() }
        Task { [self] in
            do {
                await updater.prepareForQuit()
                try await completeTermination()
            } catch {
                if updater.automaticRelaunchRequested {
                    updater.cancelAutomaticRelaunch()
                    if !(error is CancellationError) { presentSaveError(error) }
                } else { presentSaveError(error) }
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func confirmQuitIfNeeded() -> Bool {
        // No tabs are on screen during the first-run onboarding: quitting needs no confirmation.
        if onboarding == nil, pendingSiteSessionRequest == nil, pendingBrowserImport == nil,
           environment?.settings.document.interaction.warnBeforeQuitting == true {
            switch confirmQuit() {
            case .cancel: return false
            case .quit: break
            case .quitWithoutWarning:
                // Persist through the same Settings queue that termination drains before saving.
                quitPreferenceSave = Task { [environment] in
                    try await environment?.settings.updateInteraction { $0.warnBeforeQuitting = false }
                }
            }
        }
        return true
    }

    /// Quit freezes new input, drains accepted work, and durably saves before any teardown.
    /// Only an explicit diagnostic/test timeout can reject a slow command queue.
    func completeTermination(timeout: Duration? = nil) async throws {
        isPreparingToQuit = true
        for controller in windows.windows.values { controller.freezeCommandsForTermination() }
        do {
            let deadline = timeout.map { ContinuousClock.now + $0 }
            func remaining() -> Duration? { deadline.map { max(.zero, ContinuousClock.now.duration(to: $0)) } }
            let preferenceSave = quitPreferenceSave
            quitPreferenceSave = nil
            try await preferenceSave?.value
            try await settingsWindow?.model.suspendForTermination(timeout: remaining())
            while isStartingUp {
                guard deadline.map({ ContinuousClock.now < $0 }) ?? true, !Task.isCancelled else {
                    throw BrowserTerminationPreparationError.commandsDidNotSettle
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard await windows.waitForPendingCommands(timeout: remaining()) else {
                throw BrowserTerminationPreparationError.commandsDidNotSettle
            }
            guard await BrowserTermination.withDeadline(remaining(), { [self] in await waitForPrivateWindowCommands() }) else {
                throw BrowserTerminationPreparationError.commandsDidNotSettle
            }
            guard await BrowserTermination.withDeadline(remaining(), { [self] in await waitForQuickWindowCommands() }) else {
                throw BrowserTerminationPreparationError.commandsDidNotSettle
            }
            try await environment?.prepareToSaveForTermination(timeout: remaining())
            if updater.isRestartingForUpdate { try environment?.checkpointQuickWindowsForUpdate() }
            try await environment?.finalize(permitsTermination: { [self] in updater.permitsAutomaticTermination })
            try persistPendingSiteSessionImport()
        } catch {
            // Include partially created windows registered before publication by the router;
            // their accepted work remains queued and must be usable after cancellation too.
            if updater.isRestartingForUpdate { try? environment?.clearUpdateWindowCheckpoint() }
            let controllers = environment?.liveControllers ?? Array(windows.windows.values)
            for controller in controllers { controller.cancelTerminationPreparation() }
            isPreparingToQuit = false
            discardStagedPasswordImport()
            pendingSiteSessionRequest = nil
            pendingBrowserImport = nil
            wantsSiteSessionRelaunch = false
            settingsWindow?.model.resumeAfterCancelledTermination()
            environment?.terminationDidCancel()
            drainPendingExternalURLs()
            throw error
        }
        // Save succeeded: detach without mutating the model, await native teardown, then retire
        // the router. Nothing below this point is allowed to cancel termination. A bounded
        // engine teardown that timed out is reported and the quit goes on: the session is
        // saved, and the engine's own quit is bounded too (a Chromium runtime force-ends its
        // loop, then its process, CHROMIUM-APP-R2).
        commands.keyboard.uninstall()
        commands.globalQuickWindowShortcut.uninstall()
        await closePrivateWindows()
        engineShutdownOutcome = await environment?.shutDown()
        if engineShutdownOutcome == .engineShutdownTimedOut {
            FileHandle.standardError.write(Data("orbit: engine shutdown timed out; quitting with the saved session\n".utf8))
        }
        windows.shutdown()
    }

    /// Result of the engine teardown of the latest completed termination, nil before it.
    private(set) var engineShutdownOutcome: BrowserTermination.Outcome?

    /// A rescued document whose profile has no open window gets a new window in one of its Spaces.
    private func openRescueWindow(for profileID: ProfileID, preferredSpaceID: SpaceID? = nil) {
        guard !isPreparingToQuit, let environment else { return }
        Task { [weak self] in
            let document = await environment.store.sessionDocument()
            guard let self, !isPreparingToQuit,
                  let spaceID = document.spaces.first(where: {
                      $0.profileID == profileID && (preferredSpaceID == nil || $0.id == preferredSpaceID)
                  })?.id else { return }
            let id = UUID()
            rescueSpaces[id] = spaceID
            windows.newWindow(id: id)
        }
    }

    func presentSaveError(_ error: any Error) {
        guard !didPresentSaveError else { return }
        didPresentSaveError = true
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = uiText("Could Not Save the Session")
        if case BrowserTerminationPreparationError.commandsDidNotSettle = error {
            alert.informativeText = uiText("A browser operation is still in progress. Your windows and session are kept. Try quitting again when it finishes.")
        } else if case BrowserSessionFileError.replacedButDirectorySyncFailed = error {
            alert.informativeText = uiText("The new session file was saved, but its durability on disk could not be confirmed. Keep your windows open and try again before quitting.")
        } else {
            alert.informativeText = uiText("The last complete session file was kept. Keep your windows open and check the available disk space and folder permissions before trying again.")
        }
        alert.addButton(withTitle: uiText("Continue"))
        if let window = activeBrowserWindow?.window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    /// Normally a no-op: termination already detached everything after saving.
    func applicationWillTerminate(_ notification: Notification) {
        commands.keyboard.uninstall()
        commands.globalQuickWindowShortcut.uninstall()
        environment?.retireQuickWindows()
        environment?.downloads.shutdown()
        windows.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            Task { [weak self] in
                guard let self else { return }
                await startupTask?.value
                guard !isPreparingToQuit else { return }
                retryUnroutedQuickWindowURLs()
                withBrowserWindow { controller in controller.showWindow(nil) }
            }
        }
        return true
    }

    var activeBrowserWindow: OrbitWindowController? { windows.selectedWindow }

    func withBrowserWindow(
        createIfMissing: Bool = true,
        _ action: @escaping (OrbitWindowController) -> Void
    ) {
        guard !isPreparingToQuit, environment != nil else { return }
        windows.perform(createIfMissing: createIfMissing) { controller in
            controller.performAcceptedCommand { action(controller) }
        }
    }
}
