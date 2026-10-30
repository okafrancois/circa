import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct LocalFilesTests {
    private func fixture(_ body: @MainActor (URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("synthetic document.pdf")
        let html = root.appendingPathComponent("synthetic.html")
        try Data("%PDF-1.4\nsynthetic".utf8).write(to: pdf)
        try Data("<title>Synthetic</title>".utf8).write(to: html)
        try await body(pdf, html)
    }

    @Test("Native file selection accepts regular local files and preserves quarantine")
    func resolution() async throws {
        try await fixture { pdf, html in
            let attribute = "0081;00000000;Synthetic;"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            process.arguments = ["-w", "com.apple.quarantine", attribute, pdf.path]
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(ExternalURLResolver.resolve(pdf) == pdf)
            #expect(ExternalURLResolver.resolve(html) == html)
            #expect(LocalFileOpen.validURL(pdf.deletingLastPathComponent()) == nil)
            #expect(LocalFileOpen.validURL(URL(string: "file://remote.invalid/test.pdf")!) == nil)
            #expect(LocalFileOpen.validURL(pdf.appendingPathComponent("missing")) == nil)
            let read = Process(); let pipe = Pipe()
            read.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            read.arguments = ["-p", "com.apple.quarantine", pdf.path]; read.standardOutput = pipe
            try read.run(); read.waitUntilExit()
            #expect(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .newlines) == attribute)
        }
    }

    @Test("File event delivery stays in front-window tabs even with quick-window preferences")
    func eventRouting() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await fixture { pdf, html in
            let app = OrbitApplication(environment: PreviewEnvironment(), externalURLStartupComplete: false, windowPresenter: { _, _ in })
            defer { app.windows.shutdown() }
            app.application(NSApp, open: [pdf, html])
            #expect(app.windows.selectedWindowID == nil)
            app.finishExternalURLStartup()
            await app.windows.waitForPendingCommands()
            let first = try #require(app.windows.selectedWindow)
            await first.session.waitForPendingCommands()
            #expect(Array(try #require(first.session.snapshot).tabs.map(\.url).suffix(2)) == [pdf, html])
            #expect(app.quickWindowOpenRequests.isEmpty)
            let secondID = try #require(app.windows.newWindow())
            await app.windows.waitForPendingCommands()
            app.windows.activate(first.id)
            app.application(NSApp, open: [html, pdf])
            app.windows.activate(secondID)
            await first.session.waitForPendingCommands()
            #expect(Array(try #require(first.session.snapshot).tabs.map(\.url).suffix(2)) == [html, pdf])
            #expect(app.windows.windows[secondID]?.session.snapshot?.tabs.count == 1)
        }
    }

    @Test("Open File reuses the application command, supports multiple selection and cancellation")
    func command() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await fixture { pdf, html in
            let app = OrbitApplication(environment: PreviewEnvironment(), windowPresenter: { _, _ in })
            defer { app.windows.shutdown() }
            #expect(app.commands.registry.definition(.openFile)?.shortcuts == [])
            app.chooseLocalFiles = { _, completion in completion([]) }
            #expect(app.commands.registry.dispatch(.openFile, origin: .menu))
            #expect(app.windows.selectedWindowID == nil)
            app.chooseLocalFiles = { _, completion in completion([pdf, html]) }
            #expect(app.commands.registry.dispatch(.openFile, origin: .menu))
            await app.windows.waitForPendingCommands()
            let owner = try #require(app.windows.selectedWindow)
            await owner.session.waitForPendingCommands()
            #expect(Array(try #require(owner.session.snapshot).tabs.map(\.url).suffix(2)) == [pdf, html])
            let bar = app.commands.menus.makeMenuBar()
            let file = try #require(bar.items.first { $0.title == uiText("File") }?.submenu)
            let item = try #require(file.items.first { $0.identifier?.rawValue == BrowserCommandID.openFile.rawValue })
            #expect(item.title == uiText("Open File…") && item.keyEquivalent.isEmpty)
        }
    }

    @Test("File grants are exact, surface-bound, and refuse page navigation, subframes and redirects")
    func grants() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await fixture { pdf, html in
            let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
            let owner = try await environment.makeWindow()
            defer { owner.window?.close() }
            owner.submitAddress("https://synthetic.invalid/")
            await owner.session.waitForPendingCommands()
            let surface = try #require(owner.session.selectedSurface)
            @MainActor func policy(_ url: URL, _ kind: BrowserNavigationKind, main: Bool = true) -> BrowserNavigationActionPolicy {
                BrowserNavigationPolicy.action(.init(url: url, isMainFrame: main, kind: kind), surface: surface,
                    held: true, routesEnabled: false, hooks: owner.engineEventHooks)
            }
            #expect(policy(pdf, .typed) == .cancel)
            BrowserNavigationPolicy.authorizeLocalDocument(pdf, for: surface)
            #expect(policy(pdf, .typed) == .allow)
            #expect(policy(pdf, .reload) == .allow)
            #expect(policy(pdf, .backForward) == .allow)
            for kind: BrowserNavigationKind in [.linkActivation, .other, .redirect, .formSubmission] {
                #expect(policy(pdf, kind) == .cancel)
            }
            #expect(policy(pdf, .typed, main: false) == .cancel)
            #expect(policy(html, .typed) == .cancel)
            #expect(policy(URL(string: "file://remote.invalid" + pdf.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!, .typed) == .cancel)
            let response = BrowserNavigationResponse(response: URLResponse(url: pdf, mimeType: "application/pdf", expectedContentLength: 0, textEncodingName: nil), canShowMIMEType: true, isForMainFrame: false)
            #expect(BrowserNavigationPolicy.response(response, surface: surface, held: true) == .cancel)
            #expect(policy(html, .backForward) == .cancel)
            BrowserNavigationPolicy.authorizeLocalDocument(html, for: surface)
            #expect(policy(html, .typed) == .allow)
            #expect(policy(pdf, .backForward) == .allow)
            #expect(policy(pdf, .other) == .cancel)
            owner.session.openTab(url: pdf) // A model URL alone must not grant a file.
            await owner.session.waitForPendingCommands()
            let ungranted = try #require(owner.session.selectedSurface)
            #expect(BrowserNavigationPolicy.action(.init(url: pdf, isMainFrame: true, kind: .typed), surface: ungranted,
                held: true, routesEnabled: false, hooks: owner.engineEventHooks) == .cancel)
            #expect(owner.surface(ungranted, openDroppedFiles: [pdf]))
            await owner.session.waitForPendingCommands()
            #expect(BrowserNavigationPolicy.action(.init(url: pdf, isMainFrame: true, kind: .typed), surface: ungranted,
                held: true, routesEnabled: false, hooks: owner.engineEventHooks) == .allow)
            #expect(!owner.surface(ungranted, openDroppedFiles: [pdf.deletingLastPathComponent()]))
        }
    }

    @Test("Only the engine PDF component can embed the exact user-granted PDF")
    func pdfComponent() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await fixture { pdf, html in
            let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
            let owner = try await environment.makeWindow()
            defer { owner.window?.close() }
            await owner.session.waitForPendingCommands()
            let surface = try #require(owner.session.selectedSurface)
            let component = URL(string: "chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/content")!
            @MainActor func policy(_ url: URL, parent: URL?, kind: BrowserNavigationKind = .other) -> BrowserNavigationActionPolicy {
                BrowserNavigationPolicy.action(.init(url: url, isMainFrame: false, kind: kind, parentFrameURL: parent),
                    surface: surface, held: true, routesEnabled: false, hooks: owner.engineEventHooks, extensionDocuments: true)
            }
            surface.commitSyntheticDocument(pdf)
            #expect(policy(pdf, parent: component) == .cancel)
            BrowserNavigationPolicy.authorizeLocalDocument(pdf, for: surface)
            #expect(policy(pdf, parent: component) == .allow)
            #expect(policy(pdf, parent: component, kind: .redirect) == .cancel)
            #expect(policy(html, parent: component) == .cancel)
            #expect(policy(pdf, parent: nil) == .cancel)
            #expect(policy(pdf, parent: URL(string: "https://synthetic.invalid/")) == .cancel)
            #expect(policy(pdf, parent: URL(string: "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/content")) == .cancel)
            surface.commitSyntheticDocument(URL(string: "https://synthetic.invalid/")!)
            #expect(policy(pdf, parent: component) == .cancel)
        }
    }

    @Test("File paths and file URLs are native Command Bar destinations")
    func address() throws {
        let resolver = AddressResolver()
        #expect(try resolver.resolve("/tmp/synthetic document.pdf").url == URL(fileURLWithPath: "/tmp/synthetic document.pdf"))
        #expect(try resolver.resolve("file:///tmp/synthetic%20document.pdf").url == URL(fileURLWithPath: "/tmp/synthetic document.pdf"))
        #expect(throws: AddressResolutionError.self) { try resolver.resolve("file://remote.invalid/test.pdf") }
    }

    @Test("Production document claims declare PDF and HTML viewers without taking default ownership")
    func documentTypes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("OrbitChromium/App/Info.plist.in"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        for uti in ["com.adobe.pdf", "public.html", "public.xhtml"] {
            let type = try #require(types.first { ($0["LSItemContentTypes"] as? [String])?.contains(uti) == true })
            #expect(type["CFBundleTypeRole"] as? String == "Viewer")
            #expect(type["LSHandlerRank"] as? String == "Alternate")
        }
    }

    @Test("Sidebar file drops reuse the list insertion proposal and keep multi-file order")
    func sidebarDrop() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await fixture { pdf, html in
            let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
            let owner = try await environment.makeWindow()
            defer { owner.window?.close() }
            await owner.session.waitForPendingCommands()
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            let list = owner.sidebar.page.list
            let point = owner.sidebar.convert(NSPoint(x: 50, y: list.bounds.maxY - 10), from: list)
            let proposal = try #require(owner.sidebar.updateFileDrop([pdf, html], at: point))
            #expect(owner.sidebar.commitFileDrop([pdf, html], at: point))
            await owner.session.waitForPendingCommands()
            let organization = try #require(owner.session.organization)
            let files = organization.allTabs.filter { [pdf, html].contains($0.url) }
            #expect(files.map(\.url) == [pdf, html])
            #expect(proposal.gap != nil)
            #expect(!owner.sidebar.commitFileDrop([URL(string: "https://synthetic.invalid/")!], at: point))
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.writeObjects([pdf as NSURL, html as NSURL])
            #expect(BrowserSidebarView.droppedFiles(pasteboard) == [pdf, html])
        }
    }
}
}
