import AppKit

@MainActor
private final class ShellModel: NSObject, NSMenuItemValidation, NSWindowDelegate {
    private struct Host {
        var url = ""
        var title = ""
        var profile: UInt64 = 0
        var window: UInt64 = 0
        var lifetime: UInt64 = 0
        var document: UInt64 = 0
        var loaded = false
        var query = ""  // Ephemeral native UI state; never serialized or logged.
        var queryToken: UInt64 = 0
        var findOperation: UInt64 = 0
        var findPending = false
        var count: Int32?
        var ordinal: Int32?
        var zoomOperation: UInt64 = 0
        var zoomLevel: Double?
        var defaultZoomLevel: Double?
        var canZoomIn = false
        var canZoomOut = false
        var canZoomReset = false
    }

    private let pageToolsTest = CommandLine.arguments.contains("--page-tools-test")
    private let downloadTest = CommandLine.arguments.contains("--download-test")
    private var hiddenTest: Bool { pageToolsTest || downloadTest }
    private var hosts: [Int32: Host] = [:]
    private var targetID: Int32 = 0
    private var hostMenu: NSMenu?
    private var zoomMenuItem: NSMenuItem?
    private var quitting = false
    private var nextToken: UInt64 = 1
    private var findPanel: NSPanel?
    private var findField: NSSearchField?
    private var findStatus: NSTextField?
    private var findTarget: Int32 = 0
    private var findLifetime: UInt64 = 0
    private var findDocument: UInt64 = 0
    private var probeStep = "waiting-for-documents"
    private var probeOperation: UInt64 = 0
    private var probeHost: Int32 = 0
    private var probeDone = false
    private var probeFailed = false
    private var probeA: Int32 = 0
    private var probeA2: Int32 = 0
    private var probeB: Int32 = 0
    private var probeFirstOrdinal: Int32 = 0
    private var probeSecondOrdinal: Int32 = 0
    private var probeOldDocument: UInt64 = 0
    private var probeBaselineA: Double = 0
    private var probeBaselineB: Double = 0
    private var probeRaised: Double = 0
    private var closedProbeContext: (id: Int32, lifetime: UInt64, document: UInt64)?

    private struct DownloadIdentity: Equatable {
        let profile: UInt64
        let native: UInt32
        let lifetime: UInt64
        let source: Int32
        let sourceLifetime: UInt64
    }
    private struct DownloadObservation {
        let identity: DownloadIdentity
        let handle: ALChromiumDownloadHandle
        let fixtureCase: ALChromiumDownloadCase
        let received: Int64
        let total: Int64
        let status: ALChromiumDownloadStatus
        let paused: Bool
        let reason: Int32
        let canResume: Int32
        let path: String
        let filename: String
    }
    private struct DownloadRequest {
        let handle: ALChromiumDownloadHandle
        let command: UInt64
        let action: Int32
        let source: Int32
        let sourceLifetime: UInt64
        let fixtureCase: ALChromiumDownloadCase

        func matches(_ event: ALChromiumEvent) -> Bool {
            let echoed = event.download_handle
            return event.download_command_token == command && event.value == action
                && echoed.profile_token == handle.profile_token && echoed.native_id == handle.native_id
                && echoed.download_lifetime == handle.download_lifetime && echoed.revision == handle.revision
        }
    }
    private var downloads: [UInt64: DownloadObservation] = [:]
    private var downloadStep = "waiting-for-documents"
    private var downloadCase = AL_DOWNLOAD_NORMAL
    private var downloadOperation: UInt64 = 0
    private var downloadRequest: DownloadRequest?
    private var downloadA: Int32 = 0
    private var downloadA2: Int32 = 0
    private var downloadB: Int32 = 0
    private var downloadDone = false
    private var downloadFailed = false
    private var duplicatePath = ""
    private var duplicateLifetime: UInt64 = 0
    private var pauseObserved = false
    private var resumePosted = false
    private var cancelPostedReceived: Int64?
    private var interruptionObserved = false
    private var sourceClosed = false
    private var closingDownloadIdentity: DownloadIdentity?
    private var ownerRejected = false
    private var staleRejected = false
    private var closeFilePolls = 0
    private var downloadRevisionRetries = 0

    var testFailed: Bool {
        (pageToolsTest && (probeFailed || !probeDone)) || (downloadTest && (downloadFailed || !downloadDone))
    }

    private func token() -> UInt64 {
        let value = nextToken
        nextToken += 1
        return value
    }

    private func write(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    func receive(_ event: ALChromiumEvent) {
        guard event.struct_size == UInt32(MemoryLayout<ALChromiumEvent>.size) else {
            probeFailed = true
            downloadFailed = true
            return
        }
        // Copy borrowed C strings before returning. Queries are never event payloads.
        let detail = event.detail.map { String(cString: $0) } ?? ""
        let url = event.url.map { String(cString: $0) }
        let title = event.title.map { String(cString: $0) }
        var accepted = false
        switch event.kind {
        case AL_EVENT_READY:
            if !hiddenTest { installMenu() }
        case AL_EVENT_CREATED:
            hosts[event.browser_id] = Host(profile: event.profile_token, lifetime: event.host_lifetime)
            if targetID == 0 { targetID = event.browser_id }
        case AL_EVENT_ADDRESS:
            if sameLifetime(event) { hosts[event.browser_id]?.url = url ?? "" }
        case AL_EVENT_TITLE:
            if sameLifetime(event) { hosts[event.browser_id]?.title = title ?? "" }
        case AL_EVENT_WINDOW:
            if sameLifetime(event) { hosts[event.browser_id]?.window = event.window_token }
        case AL_EVENT_DOCUMENT:
            if sameLifetime(event), let host = hosts[event.browser_id], event.document_generation > host.document {
                hosts[event.browser_id]?.document = event.document_generation
                hosts[event.browser_id]?.loaded = false
                clearFindState(event.browser_id)
                hosts[event.browser_id]?.zoomLevel = nil
                hosts[event.browser_id]?.defaultZoomLevel = nil
                accepted = true
            }
        case AL_EVENT_LOADING:
            if currentDocument(event) {
                if detail == "loading-changed" {
                    hosts[event.browser_id]?.loaded = event.value == 0 && event.document_generation > 0
                    if event.value != 0 { clearFindState(event.browser_id) }
                    if event.value == 0 && !hiddenTest { _ = zoom(event.browser_id, AL_ZOOM_READ) }
                }
            }
        case AL_EVENT_FIND_RESULT:
            if currentDocument(event), let host = hosts[event.browser_id],
               host.queryToken == event.query_token, host.findOperation == event.operation_token,
               host.findOperation != 0, !host.query.isEmpty {
                hosts[event.browser_id]?.count = event.match_count
                hosts[event.browser_id]?.ordinal = event.active_ordinal
                hosts[event.browser_id]?.findPending = event.final_update == 0
                accepted = true
            }
        case AL_EVENT_FIND_STOPPED:
            if currentDocument(event), let host = hosts[event.browser_id],
               host.queryToken == event.query_token, host.findOperation == event.operation_token {
                hosts[event.browser_id]?.findPending = false
                hosts[event.browser_id]?.count = nil
                hosts[event.browser_id]?.ordinal = nil
                accepted = true
            }
        case AL_EVENT_ZOOM:
            if currentDocument(event), let host = hosts[event.browser_id],
               host.zoomOperation == event.operation_token,
               event.zoom_level.isFinite, event.default_zoom_level.isFinite {
                hosts[event.browser_id]?.zoomLevel = event.zoom_level
                hosts[event.browser_id]?.defaultZoomLevel = event.default_zoom_level
                hosts[event.browser_id]?.canZoomIn = event.can_zoom_in != 0
                hosts[event.browser_id]?.canZoomOut = event.can_zoom_out != 0
                hosts[event.browser_id]?.canZoomReset = event.can_zoom_reset != 0
                accepted = true
            }
        case AL_EVENT_PAGE_TOOLS_REJECTED:
            if currentDocument(event), hosts[event.browser_id]?.findOperation == event.operation_token {
                hosts[event.browser_id]?.findPending = false
            }
        case AL_EVENT_FOCUS:
            // A command target only; focus does not prove visual tab selection.
            if !hiddenTest && sameLifetime(event) { targetID = event.browser_id }
        case AL_EVENT_CLOSED:
            if sameLifetime(event) {
                hosts.removeValue(forKey: event.browser_id)
                if targetID == event.browser_id { targetID = hosts.keys.min() ?? 0 }
            }
        case AL_EVENT_QUIT_REQUESTED:
            quitting = true
            findPanel?.orderOut(nil)
        default:
            break
        }
        rebuildHostMenu()
        updateFindStatus()
        // Fixed native detail codes and numeric fields only. No URL/title/query logging.
        write("chromium-shell event=\(event.kind.rawValue) host=\(event.browser_id) "
            + "profile=\(event.profile_token) window=\(event.window_token) "
            + "value=\(event.value) detail=\(detail)")
        if event.kind.rawValue >= AL_EVENT_DOCUMENT.rawValue && event.kind.rawValue <= AL_EVENT_HIDDEN_AUDIT.rawValue {
            let levels = String(format: "level=%.9f default=%.9f", event.zoom_level, event.default_zoom_level)
            write("chromium-page-tools event=\(event.kind.rawValue) host=\(event.browser_id) "
                + "lifetime=\(event.host_lifetime) document=\(event.document_generation) "
                + "query=\(event.query_token) operation=\(event.operation_token) "
                + "native=\(event.native_find_id) count=\(event.match_count) ordinal=\(event.active_ordinal) "
                + "final=\(event.final_update) \(levels) in=\(event.can_zoom_in) out=\(event.can_zoom_out) "
                + "reset=\(event.can_zoom_reset) accepted=\(accepted ? 1 : 0)")
        }
        if pageToolsTest { advanceProbe(event, detail: detail, accepted: accepted) }
        if downloadTest {
            if event.kind == AL_EVENT_DOWNLOAD || event.kind == AL_EVENT_DOWNLOAD_COMMAND
                || event.kind == AL_EVENT_DOWNLOAD_REJECTED {
                writeDownloadEvent(event)
            }
            advanceDownloadProbe(event, detail: detail)
        }
    }

    private func sameLifetime(_ event: ALChromiumEvent) -> Bool {
        hosts[event.browser_id]?.lifetime == event.host_lifetime && event.host_lifetime != 0
    }

    private func currentDocument(_ event: ALChromiumEvent) -> Bool {
        sameLifetime(event) && hosts[event.browser_id]?.document == event.document_generation
    }

    private func clearFindState(_ id: Int32) {
        hosts[id]?.query = ""
        hosts[id]?.findPending = false
        hosts[id]?.findOperation = 0
        hosts[id]?.count = nil
        hosts[id]?.ordinal = nil
    }

    @discardableResult
    private func find(_ id: Int32, text: String, forward: Bool = true, next: Bool = false,
                      replace: Bool = false) -> UInt64 {
        guard !quitting, let host = hosts[id], host.document > 0, !text.isEmpty,
              text.utf8.count <= 4096, !text.contains("\0"), !text.contains("\r") else { return 0 }
        if next && !replace && (host.findPending || host.query != text || host.findOperation == 0) { return 0 }
        let query = replace || host.query != text || host.queryToken == 0 ? token() : host.queryToken
        let operation = token()
        hosts[id]?.queryToken = query
        hosts[id]?.query = text
        hosts[id]?.findOperation = operation
        hosts[id]?.findPending = true
        hosts[id]?.count = nil
        hosts[id]?.ordinal = nil
        let queued = text.withCString {
            ALChromiumFind(id, host.lifetime, host.document, query, operation, $0, forward ? 1 : 0, 0, next ? 1 : 0)
        }
        if queued == 0 { hosts[id]?.findPending = false; return 0 }
        return operation
    }

    @discardableResult
    private func stopFind(_ id: Int32) -> UInt64 {
        guard !quitting, let host = hosts[id], host.document > 0 else { return 0 }
        let query = token()
        let operation = token()
        clearFindState(id)
        hosts[id]?.queryToken = query
        hosts[id]?.findOperation = operation
        guard ALChromiumStopFinding(id, host.lifetime, host.document, query, operation, 1) != 0 else { return 0 }
        return operation
    }

    @discardableResult
    private func zoom(_ id: Int32, _ command: ALChromiumZoomCommand) -> UInt64 {
        guard !quitting, let host = hosts[id], host.document > 0 else { return 0 }
        let operation = token()
        hosts[id]?.zoomOperation = operation
        guard ALChromiumZoom(id, host.lifetime, host.document, operation, command) != 0 else { return 0 }
        return operation
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
        result.target = self
        return result
    }

    private func installMenu() {
        // Hidden mode never enters this path or accesses AppKit menus in Swift.
        let application = NSApplication.shared
        let menu = NSMenu()
        let applicationRoot = NSMenuItem()
        let applicationMenu = NSMenu(title: "Chromium Shell")
        applicationMenu.addItem(item("Quit Chromium Shell", #selector(quit), "q"))
        applicationRoot.submenu = applicationMenu
        menu.addItem(applicationRoot)
        let fileRoot = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("New Window in Target Profile", #selector(newWindow), "n"))
        fileMenu.addItem(item("New Tab in Target Window", #selector(newTab), "t"))
        fileMenu.addItem(item("Close Target Host", #selector(closeHost), "w"))
        fileMenu.addItem(item("Split Target (Two Pages)", #selector(split)))
        fileRoot.submenu = fileMenu
        menu.addItem(fileRoot)
        let editRoot = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
            ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        editMenu.addItem(.separator())
        editMenu.addItem(item("Find in Page…", #selector(showFind), "f"))
        editMenu.addItem(item("Find Next", #selector(findNext), "g"))
        let previous = item("Find Previous", #selector(findPrevious), "g")
        previous.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(previous)
        editMenu.addItem(item("Clear Find", #selector(clearFind)))
        editRoot.submenu = editMenu
        menu.addItem(editRoot)
        let viewRoot = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(item("Zoom In", #selector(zoomIn), "+"))
        viewMenu.addItem(item("Zoom Out", #selector(zoomOut), "-"))
        viewMenu.addItem(item("Actual Size", #selector(zoomReset), "0"))
        let zoomStatus = NSMenuItem(title: "Zoom: awaiting native readback", action: nil, keyEquivalent: "")
        viewMenu.addItem(zoomStatus)
        zoomMenuItem = zoomStatus
        viewRoot.submenu = viewMenu
        menu.addItem(viewRoot)
        let hostRoot = NSMenuItem()
        let knownHosts = NSMenu(title: "Known Hosts (ID Order)")
        hostRoot.submenu = knownHosts
        menu.addItem(hostRoot)
        hostMenu = knownHosts
        application.mainMenu = menu
        application.setActivationPolicy(.regular)
        application.finishLaunching()
    }

    private func rebuildHostMenu() {
        guard let hostMenu else { return }
        hostMenu.removeAllItems()
        for id in hosts.keys.sorted() {
            let row = item("Select Host \(id)", #selector(selectHost(_:)))
            row.tag = Int(id)
            row.state = id == targetID ? .on : .off
            row.isEnabled = !quitting
            hostMenu.addItem(row)
        }
        if let level = hosts[targetID]?.zoomLevel {
            // Chromium's public zoom level/factor conversion uses base 1.2.
            zoomMenuItem?.title = "Zoom: \(Int((pow(1.2, level) * 100).rounded()))%"
        } else { zoomMenuItem?.title = "Zoom: awaiting native readback" }
    }

    private func panelContextIsCurrent() -> Bool {
        guard let host = hosts[findTarget] else { return false }
        return host.lifetime == findLifetime && host.document == findDocument
    }

    private var commandFindTarget: Int32 { findPanel?.isVisible == true ? findTarget : targetID }

    private func updateFindStatus() {
        guard let status = findStatus, panelContextIsCurrent(), let host = hosts[findTarget] else {
            findStatus?.stringValue = "Document changed. Reopen Find to search it."
            return
        }
        if host.findPending { status.stringValue = "Searching…" }
        else if let count = host.count, let ordinal = host.ordinal {
            status.stringValue = "Match \(ordinal) of \(count)"
        } else { status.stringValue = "" }
    }

    @objc private func showFind() {
        guard !hiddenTest, !quitting, let host = hosts[targetID], host.document > 0 else { return }
        if findPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 108),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Find in Page"
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            let field = NSSearchField(frame: NSRect(x: 16, y: 66, width: 488, height: 26))
            field.target = self
            field.action = #selector(findChanged)
            field.sendsSearchStringImmediately = true
            field.sendsWholeSearchString = false
            field.maximumRecents = 0
            field.recentsAutosaveName = nil
            panel.contentView?.addSubview(field)
            for (index, pair) in [("Previous", #selector(findPrevious)), ("Next", #selector(findNext)),
                                  ("Clear", #selector(clearFind))].enumerated() {
                let button = NSButton(title: pair.0, target: self, action: pair.1)
                button.frame = NSRect(x: 16 + index * 100, y: 16, width: 92, height: 28)
                panel.contentView?.addSubview(button)
            }
            let status = NSTextField(labelWithString: "")
            status.frame = NSRect(x: 320, y: 20, width: 184, height: 20)
            panel.contentView?.addSubview(status)
            findPanel = panel
            findField = field
            findStatus = status
            panel.center()
        }
        findTarget = targetID
        findLifetime = host.lifetime
        findDocument = host.document
        findField?.stringValue = host.query
        updateFindStatus()
        findPanel?.makeKeyAndOrderFront(nil)
        findPanel?.makeFirstResponder(findField)
    }

    @objc private func findChanged() {
        guard panelContextIsCurrent(), let text = findField?.stringValue else { return }
        if text.isEmpty { _ = stopFind(findTarget) }
        else { _ = find(findTarget, text: text, replace: true) }
        updateFindStatus()
    }

    @objc private func findNext() { continueFind(forward: true) }
    @objc private func findPrevious() { continueFind(forward: false) }
    private func continueFind(forward: Bool) {
        let id = commandFindTarget
        guard !quitting, findPanel?.isVisible != true || panelContextIsCurrent(),
              let host = hosts[id], !host.findPending, !host.query.isEmpty else { return }
        _ = find(id, text: host.query, forward: forward, next: true)
        updateFindStatus()
    }
    @objc private func clearFind() {
        let id = commandFindTarget
        guard findPanel?.isVisible != true || panelContextIsCurrent() else { return }
        _ = stopFind(id)
        if id == findTarget { findField?.stringValue = "" }
        updateFindStatus()
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === findPanel, panelContextIsCurrent(), !quitting {
            _ = stopFind(findTarget)
            findField?.stringValue = ""
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !quitting else { return menuItem.action == #selector(quit) }
        if menuItem.action == #selector(zoomIn) { return hosts[targetID]?.canZoomIn == true }
        if menuItem.action == #selector(zoomOut) { return hosts[targetID]?.canZoomOut == true }
        if menuItem.action == #selector(zoomReset) { return hosts[targetID]?.canZoomReset == true }
        if menuItem.action == #selector(findNext) || menuItem.action == #selector(findPrevious) {
            guard let host = hosts[commandFindTarget] else { return false }
            return !host.findPending && !host.query.isEmpty && host.findOperation != 0
                && (findPanel?.isVisible != true || panelContextIsCurrent())
        }
        return true
    }

    @objc private func zoomIn() { _ = zoom(targetID, AL_ZOOM_IN) }
    @objc private func zoomOut() { _ = zoom(targetID, AL_ZOOM_OUT) }
    @objc private func zoomReset() { _ = zoom(targetID, AL_ZOOM_RESET) }
    @objc private func newWindow() { if !quitting { _ = ALChromiumCreateWindow(targetID) } }
    @objc private func newTab() { if !quitting { _ = ALChromiumNewTab(targetID) } }
    @objc private func closeHost() { if !quitting { _ = ALChromiumClose(targetID) } }
    @objc private func split() { if !quitting { _ = ALChromiumSplit(targetID) } }
    @objc private func quit() { _ = ALChromiumRequestQuit() }
    @objc private func selectHost(_ sender: NSMenuItem) {
        let id = Int32(sender.tag)
        guard !quitting, hosts[id] != nil else { return }
        targetID = id
        _ = ALChromiumSelect(id)
        _ = zoom(id, AL_ZOOM_READ)
        rebuildHostMenu()
    }

    private func writeDownloadEvent(_ event: ALChromiumEvent) {
        // Pair every native event's scalar record, even after a probe failure.
        // Failed probes may stop progressing but must not truncate the protocol.
        let handle = event.download_handle
        write("chromium-download event=\(event.kind.rawValue) case=\(event.download_case.rawValue) "
            + "profile=\(handle.profile_token) native=\(handle.native_id) lifetime=\(handle.download_lifetime) "
            + "revision=\(handle.revision) source=\(event.source_browser_id) source_lifetime=\(event.source_host_lifetime) "
            + "received=\(event.received_bytes) total=\(event.total_bytes) status=\(event.download_status.rawValue) "
            + "paused=\(event.download_paused) reason=\(event.interrupt_reason) resumable=\(event.can_resume) "
            + "command=\(event.download_command_token) action=\(event.value)")
    }

    private func downloadResult(_ step: String, _ passed: Bool, _ observation: DownloadObservation? = nil,
                                fileBytes: Int64 = -1) {
        write("chromium-download-probe step=\(step) passed=\(passed ? 1 : 0) "
            + "case=\(observation?.fixtureCase.rawValue ?? downloadCase.rawValue) "
            + "profile=\(observation?.identity.profile ?? 0) native=\(observation?.identity.native ?? 0) "
            + "lifetime=\(observation?.identity.lifetime ?? 0) revision=\(observation?.handle.revision ?? 0) "
            + "received=\(observation?.received ?? 0) total=\(observation?.total ?? -1) "
            + "status=\(observation?.status.rawValue ?? 0) source=\(observation?.identity.source ?? 0) "
            + "source_lifetime=\(observation?.identity.sourceLifetime ?? 0) file_bytes=\(fileBytes)")
    }

    private func failDownload(_ step: String, requestQuit: Bool = true) {
        guard !downloadFailed else { return }
        downloadFailed = true
        downloadResult(step, false)
        if requestQuit { _ = ALChromiumRequestQuit() }
    }

    private func currentDownload() -> DownloadObservation? {
        downloads.values.first { $0.fixtureCase == downloadCase }
    }

    private func rememberDownloadRequest(_ handle: ALChromiumDownloadHandle, action: Int32,
                                         source: Int32, sourceLifetime: UInt64,
                                         fixtureCase: ALChromiumDownloadCase) {
        // Preserve exactly what will be submitted, before entering the C ABI.
        // Later observations must never reconstruct or replace this context.
        let request = DownloadRequest(handle: handle, command: downloadOperation, action: action,
            source: source, sourceLifetime: sourceLifetime, fixtureCase: fixtureCase)
        downloadRequest = request
        write("chromium-download-request step=\(downloadStep) profile=\(handle.profile_token) "
            + "native=\(handle.native_id) lifetime=\(handle.download_lifetime) revision=\(handle.revision) "
            + "command=\(downloadOperation) action=\(action) source=\(request.source) "
            + "source_lifetime=\(request.sourceLifetime) case=\(request.fixtureCase.rawValue)")
    }

    private func rememberDownloadAdmission(_ profile: UInt64, source: Int32, sourceLifetime: UInt64,
                                           fixtureCase: ALChromiumDownloadCase) {
        // Admission rejections echo the submitted profile with a zero item
        // identity: no native download exists for that rejected start.
        rememberDownloadRequest(ALChromiumDownloadHandle(profile_token: profile, native_id: 0,
            download_lifetime: 0, revision: 0), action: 0, source: source,
            sourceLifetime: sourceLifetime, fixtureCase: fixtureCase)
    }

    private func startDownload(_ fixtureCase: ALChromiumDownloadCase) {
        guard !downloadFailed else { return }
        downloadCase = fixtureCase
        downloadStep = "transferring"
        downloadRevisionRetries = 0
        let id = fixtureCase == AL_DOWNLOAD_PROFILE_B ? downloadB
            : fixtureCase == AL_DOWNLOAD_SOURCE_CLOSE || fixtureCase == AL_DOWNLOAD_DUPLICATE_SECOND
                ? downloadA2 : downloadA
        guard let host = hosts[id] else { failDownload("source-unavailable"); return }
        downloadOperation = token()
        rememberDownloadAdmission(host.profile, source: id, sourceLifetime: host.lifetime, fixtureCase: fixtureCase)
        if ALChromiumStartDownload(id, host.lifetime, host.profile, downloadOperation, fixtureCase) == 0 {
            failDownload("start-queue-rejected")
        }
    }

    private func controlDownload(_ observation: DownloadObservation, _ action: ALChromiumDownloadAction,
                                 step: String) {
        downloadStep = step
        downloadOperation = token()
        rememberDownloadRequest(observation.handle, action: Int32(action.rawValue),
            source: observation.identity.source, sourceLifetime: observation.identity.sourceLifetime,
            fixtureCase: observation.fixtureCase)
        if ALChromiumDownloadCommand(observation.handle, downloadOperation, action) == 0 {
            failDownload("control-queue-rejected")
        }
    }

    private func confirmSourceClosed(_ identity: DownloadIdentity) {
        guard !downloadFailed, downloadCase == AL_DOWNLOAD_SOURCE_CLOSE,
              downloadStep == "source-close-check" else { return }
        // Run on the next main/UI turn, after OnBeforeClose and State::Closed
        // have unwound. The fixture remains blocked until root sees success.
        guard hosts[identity.source]?.lifetime != identity.sourceLifetime,
              let observation = downloads[identity.lifetime], observation.identity == identity,
              observation.fixtureCase == AL_DOWNLOAD_SOURCE_CLOSE,
              observation.status == AL_DOWNLOAD_PROGRESS,
              observation.received > 0, observation.received < 2_097_152,
              !observation.path.isEmpty else {
            failDownload("source-close-not-in-progress"); return
        }
        let path = observation.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        guard (attributes?[.type] as? FileAttributeType) == .typeRegular,
              size >= 0, size < 2_097_152,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else {
            failDownload("source-close-file-not-partial"); return
        }
        sourceClosed = true
        downloadStep = "source-file-wait"
        downloadResult("source-host-closed", true, observation, fileBytes: size)
        waitForClosedSourceFile(identity.lifetime)
    }

    private func waitForClosedSourceFile(_ lifetime: UInt64) {
        guard !downloadFailed, downloadStep == "source-file-wait",
              let observation = downloads[lifetime] else { return }
        closeFilePolls += 1
        let path = observation.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let regular = (attributes?[.type] as? FileAttributeType) == .typeRegular
        if sourceClosed && regular && size == 2_097_152
            && URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path {
            // Filesystem observation only. Pinned CEF stops download callbacks
            // when the source browser is destroyed; no COMPLETE is synthesized.
            downloadResult("source-close-file-observed", true, observation, fileBytes: size)
            startDownload(AL_DOWNLOAD_PROFILE_B)
        } else if attributes == nil, !fileEntryExists(path) {
            // The partial file confirmed above has been discarded. Pinned CEF
            // aborts the source browser's proxied download request on browser
            // destruction (resource_request_handler_wrapper.cc:1289-1329) and
            // Chromium maps ERR_ABORTED to a discarding user cancel
            // (download_utils.cc:247-272). Report it instead of timing out.
            failDownload("source-close-file-discarded")
        } else if closeFilePolls >= 200 {
            failDownload("source-close-file-timeout")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForClosedSourceFile(lifetime)
            }
        }
    }

    private func fileEntryExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 || errno != ENOENT
    }

    private func finishCompletedDownload(_ observation: DownloadObservation) {
        guard observation.status == AL_DOWNLOAD_COMPLETE, observation.received == 2_097_152,
              observation.total == 2_097_152, !observation.path.isEmpty else {
            failDownload("completion-bytes-mismatch"); return
        }
        switch downloadCase {
        case AL_DOWNLOAD_NORMAL:
            guard staleRejected else { return }
            downloadResult("normal-complete", true, observation)
            startDownload(AL_DOWNLOAD_DUPLICATE_FIRST)
        case AL_DOWNLOAD_DUPLICATE_FIRST:
            duplicatePath = observation.path
            duplicateLifetime = observation.identity.lifetime
            downloadResult("duplicate-first-complete", true, observation)
            startDownload(AL_DOWNLOAD_DUPLICATE_SECOND)
        case AL_DOWNLOAD_DUPLICATE_SECOND:
            guard observation.path != duplicatePath, observation.identity.lifetime != duplicateLifetime,
                  observation.identity.profile == hosts[downloadA]?.profile,
                  observation.identity.source == downloadA2 else {
                failDownload("duplicate-ownership-or-destination"); return
            }
            downloadResult("duplicate-second-complete", true, observation)
            startDownload(AL_DOWNLOAD_PAUSE_RESUME)
        case AL_DOWNLOAD_PAUSE_RESUME:
            guard pauseObserved && resumePosted else { failDownload("pause-resume-unobserved"); return }
            downloadResult("pause-resume-complete", true, observation)
            startDownload(AL_DOWNLOAD_CANCEL_PROGRESS)
        case AL_DOWNLOAD_INTERRUPT_RESUME:
            guard interruptionObserved && resumePosted else {
                failDownload("interruption-unobserved"); return
            }
            downloadResult("interrupt-resume-complete", true, observation)
            startDownload(AL_DOWNLOAD_SOURCE_CLOSE)
        case AL_DOWNLOAD_PROFILE_B:
            guard ownerRejected else { return }
            downloadResult("profile-b-complete", true, observation)
            downloadStep = "quitting"
            _ = ALChromiumRequestQuit()
        default:
            failDownload("unexpected-completion")
        }
    }

    private func advanceDownloadProbe(_ event: ALChromiumEvent, detail: String) {
        guard !downloadFailed else { return }
        if event.kind == AL_EVENT_FAILURE {
            // DownloadFailure has already revoked every callback and posted
            // its one shutdown task. Keep failure reporting non-reentrant.
            let nativeShutdownPosted = detail == "download-native-path-rejected"
                || detail == "download-native-file-rejected" || detail == "download-storage-policy-rejected"
            failDownload("native-failure", requestQuit: !nativeShutdownPosted)
            return
        }
        if event.kind == AL_EVENT_QUIT_REQUESTED && downloadStep == "quitting" {
            downloadStep = "quit-admission-wait"
            downloadOperation = token()
            guard let host = hosts[downloadA] else { failDownload("quit-source-unavailable"); return }
            rememberDownloadAdmission(host.profile, source: downloadA, sourceLifetime: host.lifetime,
                fixtureCase: AL_DOWNLOAD_NORMAL)
            if ALChromiumStartDownload(downloadA, host.lifetime, host.profile, downloadOperation,
                                       AL_DOWNLOAD_NORMAL) == 0 { failDownload("quit-probe-not-queued") }
            return
        }
        if event.kind == AL_EVENT_CLOSED && event.browser_id == downloadA2
            && downloadCase == AL_DOWNLOAD_SOURCE_CLOSE {
            guard downloadStep == "source-close-confirm-wait", let identity = closingDownloadIdentity,
                  identity.source == event.browser_id, identity.sourceLifetime == event.host_lifetime,
                  identity.profile == event.profile_token else {
                failDownload("source-close-context-mismatch"); return
            }
            downloadStep = "source-close-check"
            DispatchQueue.main.async { [weak self] in self?.confirmSourceClosed(identity) }
            return
        }
        if downloadStep == "waiting-for-documents" {
            guard hosts.count == 3, hosts.values.allSatisfy({ $0.loaded && $0.document > 0 && $0.window > 0 }) else { return }
            let groups = Dictionary(grouping: hosts.keys, by: { hosts[$0]!.profile })
            guard groups.count == 2, let a = groups.values.first(where: { $0.count == 2 })?.sorted(),
                  let b = groups.values.first(where: { $0.count == 1 })?.first,
                  let host = hosts[a[0]], let other = hosts[b] else { failDownload("profile-layout"); return }
            downloadA = a[0]; downloadA2 = a[1]; downloadB = b
            downloadResult("hidden-three-hosts-two-profiles", true)
            downloadStep = "admission-owner-wait"
            downloadOperation = token()
            rememberDownloadAdmission(other.profile, source: downloadA, sourceLifetime: host.lifetime,
                fixtureCase: AL_DOWNLOAD_NORMAL)
            if ALChromiumStartDownload(downloadA, host.lifetime, other.profile, downloadOperation,
                                       AL_DOWNLOAD_NORMAL) == 0 { failDownload("admission-probe-not-queued") }
            return
        }
        if event.kind == AL_EVENT_DOWNLOAD_REJECTED {
            guard event.download_command_token == downloadOperation,
                  let request = downloadRequest, request.matches(event) else {
                failDownload("rejection-context-mismatch"); return
            }
            if detail == "download-revision-rejected", downloadRevisionRetries < 8,
               let current = currentDownload(),
               ["pause-wait", "resume-wait", "cancel-wait", "interrupt-resume-wait"].contains(downloadStep) {
                downloadRevisionRetries += 1
                let action = downloadStep == "pause-wait" ? AL_DOWNLOAD_PAUSE
                    : downloadStep == "cancel-wait" ? AL_DOWNLOAD_CANCEL : AL_DOWNLOAD_RESUME
                controlDownload(current, action, step: downloadStep)
                return
            }
            switch downloadStep {
            case "admission-owner-wait":
                guard detail == "download-admission-rejected" else {
                    failDownload("admission-owner-reason-mismatch"); return
                }
                downloadResult("admission-owner-rejected", true)
                startDownload(AL_DOWNLOAD_NORMAL)
            case "stale-revision-wait":
                guard detail == "download-revision-rejected" else {
                    failDownload("stale-revision-reason-mismatch"); return
                }
                staleRejected = true
                downloadResult("stale-revision-rejected", true, currentDownload())
                if let current = currentDownload(), current.status == AL_DOWNLOAD_COMPLETE { finishCompletedDownload(current) }
                else { downloadStep = "transferring" }
            case "revoked-control-wait":
                guard detail == "download-control-unavailable" else {
                    failDownload("revoked-control-reason-mismatch"); return
                }
                downloadResult("revoked-control-rejected", true, currentDownload())
                resumePosted = false
                startDownload(AL_DOWNLOAD_INTERRUPT_RESUME)
            case "owner-check-wait":
                guard detail == "download-owner-rejected" else {
                    failDownload("cross-profile-reason-mismatch"); return
                }
                ownerRejected = true
                downloadResult("cross-profile-control-rejected", true, currentDownload())
                downloadStep = "transferring"
                if let current = currentDownload(), current.status == AL_DOWNLOAD_COMPLETE { finishCompletedDownload(current) }
            case "quit-admission-wait":
                guard detail == "download-admission-stopped" else {
                    failDownload("quit-admission-reason-mismatch"); return
                }
                downloadResult("quit-admission-rejected", true)
                downloadDone = true
                downloadStep = "done"
            default:
                failDownload("native-control-rejected")
            }
            return
        }
        guard event.kind == AL_EVENT_DOWNLOAD || event.kind == AL_EVENT_DOWNLOAD_COMMAND else { return }
        let handle = event.download_handle
        let identity = DownloadIdentity(profile: handle.profile_token, native: handle.native_id,
            lifetime: handle.download_lifetime, source: event.source_browser_id,
            sourceLifetime: event.source_host_lifetime)
        // Borrowed metadata is copied here and is never interpolated into logs.
        let observation = DownloadObservation(identity: identity, handle: handle,
            fixtureCase: event.download_case, received: event.received_bytes, total: event.total_bytes,
            status: event.download_status, paused: event.download_paused != 0,
            reason: event.interrupt_reason, canResume: event.can_resume,
            path: event.download_path.map { String(cString: $0) } ?? "",
            filename: event.download_filename.map { String(cString: $0) } ?? "")
        if let old = downloads[identity.lifetime] {
            guard old.identity == identity, handle.revision > old.handle.revision,
                  old.fixtureCase == observation.fixtureCase else { failDownload("immutable-identity-mismatch"); return }
        }
        guard identity.profile != 0, identity.native != 0, identity.lifetime != 0,
              identity.sourceLifetime != 0, observation.total >= -1, observation.received >= 0 else {
            failDownload("invalid-download-fields"); return
        }
        downloads[identity.lifetime] = observation
        guard observation.fixtureCase == downloadCase else { return }
        if event.kind == AL_EVENT_DOWNLOAD_COMMAND {
            guard event.download_command_token == downloadOperation else { failDownload("command-token-mismatch"); return }
            if event.value == Int32(AL_DOWNLOAD_RESUME.rawValue) { resumePosted = true }
            if event.value == Int32(AL_DOWNLOAD_CANCEL.rawValue) {
                if observation.status == AL_DOWNLOAD_PROGRESS { cancelPostedReceived = observation.received }
                downloadResult("cancel-command-revoked", true, observation)
            }
            return  // Posted is not a native state acknowledgement.
        }
        if observation.status == AL_DOWNLOAD_CANCELED {
            // Pinned Chromium d0c02bf DownloadItemImpl clears the current path on a
            // user cancel and then reports zero received bytes
            // (download_item_impl.cc:2276-2280, 2356-2368). The posted cancel
            // snapshot remembered below proves the transfer was partial.
            guard downloadCase == AL_DOWNLOAD_CANCEL_PROGRESS, downloadStep == "cancel-wait",
                  let posted = cancelPostedReceived, posted > 0 && posted < 2_097_152,
                  observation.reason == 40, observation.received == 0 else {
                failDownload("unexpected-native-cancel"); return
            }
            downloadResult("cancel-native-observed", true, observation)
            controlDownload(observation, AL_DOWNLOAD_RESUME, step: "revoked-control-wait")
            return
        }
        if observation.status == AL_DOWNLOAD_INTERRUPTED {
            guard downloadCase == AL_DOWNLOAD_INTERRUPT_RESUME, observation.reason != 0,
                  observation.canResume == -1 else { failDownload("unexpected-interruption"); return }
            if !interruptionObserved {
                interruptionObserved = true
                downloadResult("network-interruption-observed", true, observation)
                controlDownload(observation, AL_DOWNLOAD_RESUME, step: "interrupt-resume-wait")
            }
            return
        }
        if downloadCase == AL_DOWNLOAD_NORMAL && !staleRejected && downloadStep == "transferring" {
            var stale = observation.handle
            stale.revision = 0
            downloadStep = "stale-revision-wait"
            downloadOperation = token()
            rememberDownloadRequest(stale, action: Int32(AL_DOWNLOAD_CANCEL.rawValue),
                source: observation.identity.source, sourceLifetime: observation.identity.sourceLifetime,
                fixtureCase: observation.fixtureCase)
            if ALChromiumDownloadCommand(stale, downloadOperation, AL_DOWNLOAD_CANCEL) == 0 {
                failDownload("stale-probe-not-queued")
            }
            return
        }
        if downloadCase == AL_DOWNLOAD_PROFILE_B && !ownerRejected && downloadStep == "transferring" {
            guard identity.profile == hosts[downloadB]?.profile, identity.source == downloadB,
                  let a = hosts[downloadA] else { failDownload("profile-b-ownership"); return }
            var foreign = observation.handle
            foreign.profile_token = a.profile
            downloadStep = "owner-check-wait"
            downloadOperation = token()
            rememberDownloadRequest(foreign, action: Int32(AL_DOWNLOAD_CANCEL.rawValue),
                source: observation.identity.source, sourceLifetime: observation.identity.sourceLifetime,
                fixtureCase: observation.fixtureCase)
            if ALChromiumDownloadCommand(foreign, downloadOperation, AL_DOWNLOAD_CANCEL) == 0 {
                failDownload("owner-probe-not-queued")
            }
            return
        }
        if observation.status == AL_DOWNLOAD_COMPLETE {
            if downloadStep != "stale-revision-wait" && downloadStep != "owner-check-wait" {
                finishCompletedDownload(observation)
            }
            return
        }
        guard !observation.path.isEmpty, observation.status == AL_DOWNLOAD_PROGRESS else { return }
        if downloadCase == AL_DOWNLOAD_PAUSE_RESUME {
            if downloadStep == "transferring" && observation.received >= 131_072 {
                controlDownload(observation, AL_DOWNLOAD_PAUSE, step: "pause-wait")
            } else if downloadStep == "pause-wait" && observation.paused {
                pauseObserved = true
                downloadResult("pause-native-observed", true, observation)
                downloadStep = "pause-hold"
                let bytes = observation.received
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, !self.downloadFailed, self.downloadStep == "pause-hold",
                          let current = self.currentDownload(), current.paused, current.received == bytes else {
                        self?.failDownload("pause-not-stable"); return
                    }
                    self.downloadResult("pause-held", true, current)
                    self.controlDownload(current, AL_DOWNLOAD_RESUME, step: "resume-wait")
                }
            }
        } else if downloadCase == AL_DOWNLOAD_CANCEL_PROGRESS && downloadStep == "transferring"
            && observation.received >= 131_072 {
            controlDownload(observation, AL_DOWNLOAD_CANCEL, step: "cancel-wait")
        } else if downloadCase == AL_DOWNLOAD_SOURCE_CLOSE && downloadStep == "transferring"
            && observation.received >= 131_072 {
            guard observation.received < 2_097_152 else {
                failDownload("source-close-already-full"); return
            }
            closingDownloadIdentity = identity
            downloadStep = "source-close-confirm-wait"
            guard ALChromiumClose(downloadA2) != 0 else { failDownload("source-close-not-queued"); return }
        }
    }

    // The hidden probe only calls the same queued C ABI used by native menus.
    // The HTTP fixture supplies ordinary text; it cannot issue native commands.
    private func beginStep(_ name: String, host: Int32, operation: UInt64) {
        probeStep = name
        probeHost = host
        probeOperation = operation
        write("chromium-page-tools step=\(name) status=issued token=\(operation)")
        if operation == 0 { failProbe("queue-rejected") }
    }
    private func passStep() {
        write("chromium-page-tools step=\(probeStep) status=passed token=\(probeOperation)")
    }
    private func failProbe(_ reason: String) {
        guard !probeFailed else { return }
        probeFailed = true
        write("chromium-page-tools step=\(probeStep) status=failed reason=\(reason)")
        _ = ALChromiumRequestQuit()
    }
    private func check(_ condition: Bool, _ reason: String) -> Bool {
        if !condition { failProbe(reason) }
        return condition
    }
    private func findStep(_ name: String, text: String, next: Bool = false,
                          forward: Bool = true, replace: Bool = false) {
        beginStep(name, host: probeA, operation: find(probeA, text: text, forward: forward, next: next, replace: replace))
    }
    private func zoomStep(_ name: String, host: Int32, command: ALChromiumZoomCommand) {
        beginStep(name, host: host, operation: zoom(host, command))
    }

    private func advanceProbe(_ event: ALChromiumEvent, detail: String, accepted: Bool) {
        guard !probeDone, !probeFailed else { return }
        if event.kind == AL_EVENT_FAILURE || event.kind == AL_EVENT_WATCHDOG_REQUIRED {
            failProbe("native-failure")
            return
        }
        if event.kind == AL_EVENT_LOADING && detail == "main-load-error" {
            failProbe("fixture-load-error")
            return
        }
        if probeStep == "waiting-for-documents" {
            guard hosts.count == 3 else { return }
            func fixture(_ suffix: String) -> Int32? {
                hosts.first { $0.value.url.hasSuffix("/page?case=" + suffix)
                    && $0.value.document > 0 && $0.value.loaded && $0.value.window != 0 }?.key
            }
            guard let a = fixture("page-tools-a"), let a2 = fixture("page-tools-a2"),
                  let b = fixture("page-tools-b") else { return }
            guard check(a != a2 && a != b && a2 != b
                && hosts[a]?.profile == hosts[a2]?.profile && hosts[a]?.profile != hosts[b]?.profile,
                "profile-context-mismatch") else { return }
            probeA = a; probeA2 = a2; probeB = b
            passStep()
            findStep("count-only", text: "orbitneedle", replace: true)
            return
        }
        if probeStep == "navigation-commit" {
            guard event.browser_id == probeA, event.kind == AL_EVENT_LOADING,
                  detail == "loading-changed", event.value == 0,
                  let host = hosts[probeA], host.document > probeOldDocument else { return }
            passStep()
            let operation = token()
            let query = token()
            let queued = "orbitneedle".withCString {
                ALChromiumFind(probeA, host.lifetime, probeOldDocument, query, operation, $0, 1, 0, 0)
            }
            beginStep("stale-document-find", host: probeA, operation: queued != 0 ? operation : 0)
            return
        }
        if probeStep == "close-pending" {
            guard event.kind == AL_EVENT_CLOSED, event.browser_id == probeB,
                  let old = closedProbeContext else { return }
            passStep()
            let operation = token()
            let queued = ALChromiumZoom(old.id, old.lifetime, old.document, operation, AL_ZOOM_READ)
            beginStep("closed-host-rejection", host: old.id, operation: queued != 0 ? operation : 0)
            return
        }
        guard event.browser_id == probeHost, event.operation_token == probeOperation else { return }
        if event.kind == AL_EVENT_PAGE_TOOLS_REJECTED {
            handleProbeRejection(event, detail: detail)
            return
        }
        if event.kind == AL_EVENT_FIND_RESULT && accepted && event.final_update != 0 {
            handleProbeFind(event)
        } else if event.kind == AL_EVENT_FIND_STOPPED && accepted && probeStep == "stop-pending" {
            passStep()
            guard let host = hosts[probeA] else { failProbe("missing-host"); return }
            let operation = token()
            let queued = "orbitneedle".withCString {
                ALChromiumFind(probeA, host.lifetime, host.document, host.queryToken - 1, operation, $0, 1, 0, 1)
            }
            beginStep("stale-query-rejection", host: probeA, operation: queued != 0 ? operation : 0)
        } else if event.kind == AL_EVENT_ZOOM && accepted { handleProbeZoom(event) }
    }

    private func handleProbeFind(_ event: ALChromiumEvent) {
        let count = event.match_count
        let ordinal = event.active_ordinal
        switch probeStep {
        case "count-only":
            guard check(count == 3 && ordinal == 0, "count-only-native-result") else { return }
            passStep(); findStep("first-selection", text: "orbitneedle", next: true)
        case "first-selection":
            guard check(count == 3 && (1...3).contains(ordinal), "first-selection-native-result") else { return }
            probeFirstOrdinal = ordinal
            passStep(); findStep("next", text: "orbitneedle", next: true)
        case "next":
            guard check(count == 3 && ordinal == probeFirstOrdinal % 3 + 1, "next-native-result") else { return }
            probeSecondOrdinal = ordinal
            passStep(); findStep("previous", text: "orbitneedle", next: true, forward: false)
        case "previous":
            guard check(count == 3 && ordinal == probeFirstOrdinal && ordinal != probeSecondOrdinal,
                        "previous-native-result") else { return }
            passStep(); findStep("zero", text: "orbitabsentneedle", replace: true)
        case "zero":
            guard check(count == 0 && ordinal == 0, "zero-native-result") else { return }
            passStep()
            _ = find(probeA, text: "orbitneedle", replace: true)
            findStep("replace-pending", text: "orbitreplacement", replace: true)
        case "replace-pending":
            guard check(count == 2 && ordinal == 0, "replacement-native-result") else { return }
            passStep()
            _ = find(probeA, text: "orbitneedle", replace: true)
            beginStep("stop-pending", host: probeA, operation: stopFind(probeA))
        default:
            failProbe("unexpected-find-result")
        }
    }

    private func handleProbeRejection(_ event: ALChromiumEvent, detail: String) {
        switch probeStep {
        case "stale-query-rejection":
            guard check(detail == "stale-query-token", "query-rejection-reason"),
                  let host = hosts[probeA] else { return }
            passStep()
            _ = find(probeA, text: "orbitneedle", replace: true)
            probeOldDocument = host.document
            let operation = token()
            let queued = ALChromiumPageToolsReload(probeA, host.lifetime, host.document, operation)
            beginStep("navigation-commit", host: probeA, operation: queued != 0 ? operation : 0)
        case "stale-document-find":
            guard check(detail == "stale-target-context" && event.document_generation == probeOldDocument,
                        "find-stale-context"), let host = hosts[probeA] else { return }
            passStep()
            let operation = token()
            let queued = ALChromiumStopFinding(probeA, host.lifetime, probeOldDocument, token(), operation, 1)
            beginStep("stale-document-stop", host: probeA, operation: queued != 0 ? operation : 0)
        case "stale-document-stop":
            guard check(detail == "stale-target-context" && event.document_generation == probeOldDocument,
                        "stop-stale-context"), let host = hosts[probeA] else { return }
            passStep()
            let operation = token()
            let queued = ALChromiumZoom(probeA, host.lifetime, probeOldDocument, operation, AL_ZOOM_IN)
            beginStep("stale-document-zoom", host: probeA, operation: queued != 0 ? operation : 0)
        case "stale-document-zoom":
            guard check(detail == "stale-target-context", "zoom-stale-context"), let host = hosts[probeA] else { return }
            passStep()
            let operation = token()
            let queued = ALChromiumZoom(probeA, host.lifetime + 1, host.document, operation, AL_ZOOM_IN)
            beginStep("stale-lifetime-rejection", host: probeA, operation: queued != 0 ? operation : 0)
        case "stale-lifetime-rejection":
            guard check(detail == "stale-target-context", "lifetime-rejection-reason") else { return }
            passStep(); zoomStep("baseline-a", host: probeA, command: AL_ZOOM_READ)
        case "closed-host-rejection":
            guard check(detail == "stale-target-context", "closed-rejection-reason") else { return }
            passStep()
            probeDone = true
            write("chromium-page-tools step=complete status=passed token=0")
            _ = ALChromiumRequestQuit()
        default:
            failProbe("unexpected-native-rejection")
        }
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
    private func handleProbeZoom(_ event: ALChromiumEvent) {
        let level = event.zoom_level
        switch probeStep {
        case "baseline-a":
            guard check(near(level, event.default_zoom_level), "fresh-profile-a-zoom") else { return }
            probeBaselineA = level
            passStep(); zoomStep("baseline-a2", host: probeA2, command: AL_ZOOM_READ)
        case "baseline-a2":
            guard check(near(level, probeBaselineA), "same-profile-baseline") else { return }
            passStep(); zoomStep("baseline-b", host: probeB, command: AL_ZOOM_READ)
        case "baseline-b":
            guard check(near(level, event.default_zoom_level), "fresh-profile-b-zoom") else { return }
            probeBaselineB = level
            passStep(); zoomStep("zoom-in-a", host: probeA, command: AL_ZOOM_IN)
        case "zoom-in-a":
            guard check(level > probeBaselineA, "zoom-in-native-readback") else { return }
            probeRaised = level
            passStep(); zoomStep("shared-profile-zoom", host: probeA2, command: AL_ZOOM_READ)
        case "shared-profile-zoom":
            guard check(near(level, probeRaised), "shared-profile-native-readback") else { return }
            passStep(); zoomStep("isolated-profile-zoom", host: probeB, command: AL_ZOOM_READ)
        case "isolated-profile-zoom":
            guard check(near(level, probeBaselineB), "isolated-profile-native-readback") else { return }
            passStep(); zoomStep("zoom-out-a2", host: probeA2, command: AL_ZOOM_OUT)
        case "zoom-out-a2":
            guard check(near(level, probeBaselineA), "zoom-out-native-readback") else { return }
            passStep(); zoomStep("shared-profile-restore", host: probeA, command: AL_ZOOM_READ)
        case "shared-profile-restore":
            guard check(near(level, probeBaselineA), "shared-profile-restored-readback") else { return }
            passStep(); zoomStep("zoom-in-b", host: probeB, command: AL_ZOOM_IN)
        case "zoom-in-b":
            guard check(level > probeBaselineB, "isolated-profile-increase") else { return }
            passStep(); zoomStep("isolation-reverse", host: probeA, command: AL_ZOOM_READ)
        case "isolation-reverse":
            guard check(near(level, probeBaselineA), "reverse-isolation-readback") else { return }
            passStep(); zoomStep("reset-b", host: probeB, command: AL_ZOOM_RESET)
        case "reset-b":
            guard check(near(level, event.default_zoom_level), "reset-b-native-readback") else { return }
            passStep(); zoomStep("increase-before-reset-a", host: probeA, command: AL_ZOOM_IN)
        case "increase-before-reset-a":
            guard check(level > probeBaselineA, "increase-before-reset-readback") else { return }
            passStep(); zoomStep("reset-a", host: probeA, command: AL_ZOOM_RESET)
        case "reset-a":
            guard check(near(level, event.default_zoom_level), "reset-a-native-readback"),
                  let host = hosts[probeB] else { return }
            passStep()
            closedProbeContext = (probeB, host.lifetime, host.document)
            let operation = find(probeB, text: "orbitneedle", replace: true)
            guard check(ALChromiumClose(probeB) != 0, "close-queue-rejected") else { return }
            beginStep("close-pending", host: probeB, operation: operation)
        default:
            failProbe("unexpected-zoom-result")
        }
    }
}

// Explicit ownership spans the entire blocking call, including CEF shutdown.
private let model = ShellModel()
private let callbackContext = Unmanaged.passRetained(model)
var callbacks = ALChromiumCallbacks(
    abi_version: AL_CHROMIUM_ABI_VERSION,
    struct_size: UInt32(MemoryLayout<ALChromiumCallbacks>.size),
    event: { context, event in
        guard let context, let event else { return }
        MainActor.assumeIsolated {
            Unmanaged<ShellModel>.fromOpaque(context).takeUnretainedValue().receive(event.pointee)
        }
    }
)
let result = ALChromiumRun(CommandLine.argc, CommandLine.unsafeArgv, &callbacks,
                           callbackContext.toOpaque())
callbackContext.release()
exit(result == 0 && model.testFailed ? 1 : result)
