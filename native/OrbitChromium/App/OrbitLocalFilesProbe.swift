import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import QuartzCore

/// Opt-in native file-opening checks. Every fixture and output stays in the synthetic root.
@MainActor
enum OrbitLocalFilesProbe {
    static func run(_ app: OrbitApplication, owner: OrbitWindowController, root: URL,
                    command: [String: String]) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.local-files-pdf",
              let confinement = activeSyntheticDataGuard(), (try? confinement.checkInside(root)) != nil,
              let window = owner.window,
              NSRunningApplication.current.processIdentifier == getpid(), window.windowController === owner else { return ["refused": true] }
        let appearance = command["appearance"] ?? "light"
        NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let file = root.appendingPathComponent("synthetic.pdf")
        let captures = root.appendingPathComponent("captures")
        try? FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let operation = command["operation"] ?? "status"
        if operation == "panel" || operation == "panel-choose" {
            NSApp.activate(ignoringOtherApps: true)
            owner.window?.makeKey()

            _ = app.commands.registry.dispatch(.openFile, origin: .menu)
        } else if operation == "typed" {
            owner.submitAddress(file.path)
            await owner.session.waitForPendingCommands()
        } else if operation == "sidebar" {
            let list = owner.sidebar.page.list
            let point = owner.sidebar.convert(NSPoint(x: 50, y: list.bounds.maxY - 20), from: list)
            _ = owner.sidebar.updateFileDrop([file], at: point)
            try? await Task.sleep(for: .milliseconds(400))
            captureView(window.contentView, to: captures.appendingPathComponent("sidebar-drop-" + appearance + ".png"))
            _ = owner.sidebar.commitFileDrop([file], at: point)
            await owner.session.waitForPendingCommands()
        } else if operation == "menu", let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.items.contains { $0.identifier?.rawValue == BrowserCommandID.openFile.rawValue } }) {
            let copy = menu.copy() as! NSMenu
            let target = LocalFileMenuCapture(menu: copy, file: captures.appendingPathComponent("file-menu-" + appearance + ".png"))
            let timer = Timer(timeInterval: 0.25, target: target, selector: #selector(LocalFileMenuCapture.capture), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .common)
            if let view = window.contentView, let event = NSEvent.mouseEvent(with: .rightMouseDown,
                location: NSPoint(x: 80, y: 400), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSMenu.popUpContextMenu(copy, with: event, for: view)
            }
        }
        if operation == "panel-choose", let panel = window.attachedSheet as? NSOpenPanel {
            panel.directoryURL = root
            panel.nameFieldStringValue = file.lastPathComponent
        }
        if operation == "visible" {
            window.setFrame(NSRect(x: 40, y: 40, width: 1020, height: 720), display: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if operation == "content", let surface = owner.session.selectedSurface {
            let host = surface.hostView
            let location = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.writeObjects([file as NSURL])
            let drop = LocalFileDraggingInfo(window: window, pasteboard: pasteboard, location: location)
            var target = window.contentView?.hitTest(location)
            while let current = target, current.registeredDraggedTypes.isEmpty { target = current.superview }
            let accepted = target?.performDragOperation(drop) ?? false
            await owner.session.waitForPendingCommands()
            return ["nativeDestination": target.map { NSStringFromClass(type(of: $0)) } ?? "missing", "accepted": accepted]
        }
        if let sheet = window.attachedSheet {
            captureView(sheet.contentView, to: captures.appendingPathComponent("open-panel-" + appearance + ".png"))
        }
        var result: [String: Any] = ["pid": getpid(), "tabCount": owner.session.snapshot?.tabs.count ?? 0,
            "fileTabs": owner.session.snapshot?.tabs.filter { $0.url.isFileURL }.count ?? 0,
            "windowNumber": window.windowNumber, "sheet": window.attachedSheet != nil,
            "menuTitles": NSApp.mainMenu?.items.map(\.title) ?? []]
        if let surface = owner.session.selectedSurface {
            result["isFile"] = surface.navigationState.committedURL?.isFileURL == true
            result["loading"] = surface.navigationState.isLoading
            result["document"] = await OrbitPerformanceProbe.evaluate(surface,
                "({title:document.title, contentType:document.contentType, embeds:[...document.querySelectorAll('embed')].map(e=>({type:e.type,src:e.src})), text:document.body?.innerText.slice(0,120)})") ?? [:]
            if operation == "inspect" {
                var events: [[String: String]] = []
                surface.onEngineEvent = { name, fields in
                    if ["before-browse", "load-error", "commit"].contains(name) { events.append(fields.merging(["event": name]) { a, _ in a }) }
                }
                surface.reload()
                try? await Task.sleep(for: .seconds(2))
                result["events"] = events
                let (ok, treeData) = await surface.devToolsCall("Page.getFrameTree")
                if ok, let tree = try? JSONSerialization.jsonObject(with: treeData) as? [String: Any] {
                    result["tree"] = tree
                    func frames(_ node: [String: Any]) -> [String] {
                        let own = (node["frame"] as? [String: Any])?["id"] as? String
                        return (own.map { [$0] } ?? []) + (node["childFrames"] as? [[String: Any]] ?? []).flatMap(frames)
                    }
                    var inspections: [[String: Any]] = []
                    for id in frames(tree["frameTree"] as? [String: Any] ?? [:]) {
                        let params = try! JSONSerialization.data(withJSONObject: ["frameId": id, "worldName": "LocalFileProbe"])
                        let (created, worldData) = await surface.devToolsCall("Page.createIsolatedWorld", params: String(decoding: params, as: UTF8.self))
                        guard created, let world = try? JSONSerialization.jsonObject(with: worldData) as? [String: Any], let context = world["executionContextId"] as? Int else { continue }
                        let expression = "(() => {const all=[]; const visit=(r)=>{for(const e of r.querySelectorAll('*')){if(['PDF-VIEWER','EMBED','IFRAME'].includes(e.tagName))all.push({tag:e.tagName,html:e.outerHTML.slice(0,2000)});if(e.shadowRoot)visit(e.shadowRoot)}};visit(document);return {url:location.href,all,text:document.body?.innerText.slice(0,500)}})()"
                        let data = try! JSONSerialization.data(withJSONObject: ["expression": expression, "contextId": context, "returnByValue": true])
                        let (_, reply) = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: data, as: UTF8.self))
                        if let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] { inspections.append(json) }
                    }
                    result["frames"] = inspections
                }
            }
            let (ok, targets) = await surface.devToolsCall("Target.getTargets", params: "{}")
            if ok, let json = try? JSONSerialization.jsonObject(with: targets) { result["targets"] = json }
            if operation == "capture", let snapshot = try? await surface.captureSnapshot(.init(width: 1024, documentGeneration: surface.documentGeneration)) {
                let bitmap = NSBitmapImageRep(cgImage: snapshot.image)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: captures.appendingPathComponent("pdf-" + appearance + ".png"))
                captureView(window.contentView, to: captures.appendingPathComponent("browser-" + appearance + ".png"))
            }
        }
        return result
    }

    private static func captureView(_ view: NSView?, to file: URL) {
        guard let view else { return }
        view.layoutSubtreeIfNeeded(); view.display()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
    }
}

@MainActor
private final class LocalFileMenuCapture: NSObject {
    let menu: NSMenu
    let file: URL
    init(menu: NSMenu, file: URL) { self.menu = menu; self.file = file }
    @objc func capture() {
        let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        if let row = rows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid())
            && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }),
           let number = row[kCGWindowNumber as String] as? Int {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(number), file.path]
            try? process.run(); process.waitUntilExit()
        }
        if !FileManager.default.fileExists(atPath: file.path),
           let view = NSApp.windows.first(where: { $0.level.rawValue > NSWindow.Level.normal.rawValue })?.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            // Native objects in this application cannot refer to another process's view tree.
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
        }
        menu.cancelTracking()
    }
}

@MainActor
private final class LocalFileDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any? { nil }
    let draggingLocation: NSPoint
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(window: NSWindow, pasteboard: NSPasteboard, location: NSPoint) {
        draggingDestinationWindow = window; draggingPasteboard = pasteboard; draggingLocation = location
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
