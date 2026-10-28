import AppKit
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
@testable import BrowserShell
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Orbit

// CHROMIUM-APP product guarantees that do not need CEF: configuration of the data root and secure
// storage, cold-launch open requests, page-first key receipts and shell window announcements.

@Suite("Chromium product configuration")
struct OrbitProductConfigurationTests {
    @Test("Unpackaged CMake output is inert even with synthetic defaults")
    func unpackagedBundleCannotStart() {
        #expect(throws: OrbitProductConfiguration.Failure.unpackagedBundle) {
            try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: [
                "CFBundleIdentifier": "io.github.okatech.orbit.test.orbit.unpackaged", "OrbitDataRoot": "/tmp/synthetic",
                "OrbitUseMockKeychain": true, "OrbitSyntheticBundle": true
            ], applicationSupport: URL(fileURLWithPath: "/tmp/synthetic-support"), build: .stableProductForTests)
        }
    }

    private let support = URL(fileURLWithPath: "/Users/synthetic/Library/Application Support", isDirectory: true)
    private var personal: URL { support.appendingPathComponent("Orbit", isDirectory: true) }
    /// The packaged product signed with the stable local identity.
    private let stable = OrbitBuildIdentity.stableProductForTests

    @Test("Without arguments the product uses the personal data root and the real Keychain item")
    func productDefaults() throws {
        let configuration = try OrbitProductConfiguration(arguments: ["/Applications/Orbit.app/Contents/MacOS/Orbit"],
                                                         infoDictionary: [:], applicationSupport: support, build: stable)
        #expect(configuration.dataRoot == personal.standardizedFileURL)
        #expect(configuration.secureStorage == .keychain(service: "Orbit Safe Storage", account: "Orbit"))
        #expect(configuration.sessionFile.path == personal.path + "/session.json")
        #expect(configuration.engineRoot.path == personal.path + "/Chromium")
        #expect(!configuration.usesMockKeychain)
    }

    @Test("Automated runs need the mock Keychain with an explicit synthetic root")
    func syntheticRuns() throws {
        let synthetic = try OrbitProductConfiguration(arguments: ["Orbit", "--use-mock-keychain", "--orbit-data-root=/private/tmp/orbit-run/data"],
                                                     applicationSupport: support, build: stable)
        #expect(synthetic.secureStorage == .mockKeychain)
        #expect(synthetic.dataRoot.path == "/private/tmp/orbit-run/data")
        #expect(synthetic.engineRoot.path == "/private/tmp/orbit-run/data/Chromium")
        #expect(throws: OrbitProductConfiguration.Failure.mockKeychainNeedsSyntheticRoot) {
            try OrbitProductConfiguration(arguments: ["Orbit", "--use-mock-keychain"], applicationSupport: support, build: stable)
        }
        for root in [personal.path, personal.path + "/nested", support.path + "/ORBIT/x"] {
            #expect(throws: OrbitProductConfiguration.Failure.mockKeychainOnPersonalRoot) {
                try OrbitProductConfiguration(arguments: ["Orbit", "--use-mock-keychain", "--orbit-data-root=" + root],
                                             applicationSupport: support, build: stable)
            }
        }
    }

    @Test("A configurable product root keeps the real Keychain; malformed options refuse")
    func productRootAndRefusals() throws {
        let custom = try OrbitProductConfiguration(arguments: ["Orbit", "--orbit-data-root=/Volumes/Data/Orbit"], applicationSupport: support, build: stable)
        #expect(custom.secureStorage == .keychain(service: "Orbit Safe Storage", account: "Orbit"))
        #expect(throws: OrbitProductConfiguration.Failure.dataRootNotAbsolute) {
            try OrbitProductConfiguration(arguments: ["Orbit", "--orbit-data-root=relative"], applicationSupport: support, build: stable)
        }
        #expect(throws: OrbitProductConfiguration.Failure.repeatedOption("--orbit-data-root")) {
            try OrbitProductConfiguration(arguments: ["Orbit", "--orbit-data-root=/a", "--orbit-data-root=/b"], applicationSupport: support, build: stable)
        }
        #expect(throws: OrbitProductConfiguration.Failure.retiredOption("--orbit-chromium-root")) {
            try OrbitProductConfiguration(arguments: ["Orbit", "--orbit-chromium-root=/a", "--use-mock-keychain"], applicationSupport: support, build: stable)
        }
    }

    @Test("Info.plist settings of a synthetic bundle follow the same rules, never doubled by an argument")
    func infoDictionarySettings() throws {
        let info: [String: Any] = ["OrbitDataRoot": "/private/tmp/orbit-plist/data", "OrbitUseMockKeychain": true]
        let configuration = try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: info, applicationSupport: support, build: stable)
        #expect(configuration.secureStorage == .mockKeychain)
        #expect(configuration.dataRoot.path == "/private/tmp/orbit-plist/data")
        #expect(throws: OrbitProductConfiguration.Failure.repeatedOption("--orbit-data-root")) {
            try OrbitProductConfiguration(arguments: ["Orbit", "--orbit-data-root=/private/tmp/other"], infoDictionary: info,
                                         applicationSupport: support, build: stable)
        }
        #expect(throws: OrbitProductConfiguration.Failure.mockKeychainNeedsSyntheticRoot) {
            try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: ["OrbitUseMockKeychain": true], applicationSupport: support, build: stable)
        }
    }

    @Test("A test bundle launched without arguments is confined before creating any directories")
    func bakedTestLaunch() throws {
        let info: [String: Any] = ["CFBundleIdentifier": "io.github.okatech.orbit.test.orbit.daily-test",
            "OrbitDataRoot": "/private/tmp/orbit-daily-test/data", "OrbitUseMockKeychain": true,
            "OrbitSyntheticBundle": true]
        let configuration = try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: info, applicationSupport: support, build: stable)
        #expect(configuration.dataRoot.path == "/private/tmp/orbit-daily-test/data")
        #expect(configuration.usesMockKeychain)
        let runner = try OrbitProductConfiguration(arguments: ["Orbit", "--use-mock-keychain",
            "--orbit-data-root=/private/tmp/orbit-other-run/data"], infoDictionary: info, applicationSupport: support, build: stable)
        #expect(runner.usesMockKeychain)
        #expect(runner.dataRoot.path == "/private/tmp/orbit-other-run/data")
        for unsafe: [String: Any] in [
            ["CFBundleIdentifier": "io.github.okatech.orbit.test.orbit-chromium.app-smoke"],
            ["CFBundleIdentifier": "io.github.okatech.orbit.test.orbit.test"],
            ["CFBundleIdentifier": "io.github.okatech.orbit.test.orbit.test", "OrbitUseMockKeychain": true],
            ["CFBundleIdentifier": "io.github.okatech.orbit.test.orbit.test", "OrbitDataRoot": "/private/tmp/test"],
        ] {
            #expect(throws: OrbitProductConfiguration.Failure.testBundleNeedsIsolation) {
                try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: unsafe, applicationSupport: support, build: stable)
            }
        }
        var personalInfo = info
        personalInfo["OrbitDataRoot"] = personal.path
        #expect(throws: OrbitProductConfiguration.Failure.mockKeychainOnPersonalRoot) {
            try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: personalInfo, applicationSupport: support, build: stable)
        }
    }

    @Test("The product identity defaults to real storage and refuses synthetic plist settings")
    func productIdentity() throws {
        let configuration = try OrbitProductConfiguration(arguments: ["Orbit"],
            infoDictionary: ["CFBundleIdentifier": "io.github.okatech.orbit"], applicationSupport: support, build: stable)
        #expect(configuration.dataRoot == personal.standardizedFileURL)
        #expect(!configuration.usesMockKeychain)
        #expect(throws: OrbitProductConfiguration.Failure.productBundleHasSyntheticSettings) {
            try OrbitProductConfiguration(arguments: ["Orbit"], infoDictionary: [
                "CFBundleIdentifier": "io.github.okatech.orbit", "OrbitDataRoot": "/private/tmp/test",
                "OrbitUseMockKeychain": true], applicationSupport: support, build: stable)
        }
    }

    @Test("The Chromium build's default session file is its data root's; WebKit keeps Orbit Native")
    func defaultSessionFile() throws {
        let configuration = try PreviewLaunchConfiguration(arguments: ["Orbit"])
        #expect(configuration.sessionFile?.path.hasSuffix("/Orbit Native/session.json") == true)
    }
}

@MainActor
private final class OpenRecorder: NSObject, NSApplicationDelegate {
    var batches: [[URL]] = []
    func application(_ application: NSApplication, open urls: [URL]) { batches.append(urls) }
}

@MainActor
private final class SilentDelegate: NSObject, NSApplicationDelegate {}

extension NativeWebKitTests {
@Suite("Cold-launch open queue", .serialized)
@MainActor
struct ColdLaunchOpenQueueTests {
    private func getURL(_ text: String) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: text), forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    private func openDocuments(_ urls: [URL]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        for (index, url) in urls.enumerated() { list.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1) }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    @Test("Requests before the delegate are kept in order, delivered once, then forwarded directly")
    func queuesUntilDelegate() {
        let queue = ColdLaunchOpenQueue()
        let reply = NSAppleEventDescriptor.null()
        queue.handleGetURL(getURL("https://cold.test/first"), withReplyEvent: reply)
        queue.handleOpenDocuments(openDocuments([URL(fileURLWithPath: "/private/tmp/cold-page.html")]), withReplyEvent: reply)
        queue.handleGetURL(getURL("https://cold.test/second"), withReplyEvent: reply)
        #expect(queue.pending.map(\.absoluteString) == ["https://cold.test/first", "file:///private/tmp/cold-page.html",
                                                       "https://cold.test/second"])
        let recorder = OpenRecorder()
        queue.deliver(to: recorder, application: NSApplication.shared)
        #expect(recorder.batches.map { $0.map(\.absoluteString) } == [["https://cold.test/first",
            "file:///private/tmp/cold-page.html", "https://cold.test/second"]])
        #expect(queue.pending.isEmpty)
        queue.handleGetURL(getURL("https://cold.test/later"), withReplyEvent: reply)
        #expect(recorder.batches.last?.map(\.absoluteString) == ["https://cold.test/later"])
    }

    @Test("A delegate without application(_:open:) keeps the requests; a malformed GURL is ignored")
    func keepsWithoutHandler() {
        let queue = ColdLaunchOpenQueue()
        let reply = NSAppleEventDescriptor.null()
        queue.handleGetURL(getURL(""), withReplyEvent: reply)
        queue.handleGetURL(getURL("https://cold.test/kept"), withReplyEvent: reply)
        let silent = SilentDelegate()
        queue.deliver(to: silent, application: NSApplication.shared)
        #expect(queue.pending.map(\.absoluteString) == ["https://cold.test/kept"])
    }
}
}

extension NativeWebKitTests {
@Suite("Page-first key receipts")
@MainActor
struct PageKeyReceiptTests {
    private let window = UUID()
    private func context(revision: UInt64 = 1, surface: ObjectIdentifier? = ObjectIdentifier(NSObject.self),
                         generation: UInt64 = 7) -> BrowserCommandContext {
        BrowserCommandContext(revision: revision, surface: surface, documentGeneration: generation, inputToken: UUID())
    }

    @Test("A receipt runs its key once, for the same window, selection, document and focus")
    func acceptsOnce() {
        let captured = context()
        let receipt = BrowserKeyReceipt(context: BrowserPageKeyContext(windowID: window, context: captured))
        #expect(BrowserPageKeyContext.accepts(receipt, windowID: window, current: captured, isKeyWindow: true,
                                              isSelected: true, focusInsideDocument: true))
        #expect(!BrowserPageKeyContext.accepts(receipt, windowID: window, current: captured, isKeyWindow: true,
                                               isSelected: true, focusInsideDocument: true), "a receipt answers one key")
    }

    @Test("Any change between the page and the unhandled answer drops the key")
    func refusesChanges() {
        let captured = context()
        func accepts(_ current: BrowserCommandContext?, window: UUID? = nil, key: Bool = true, selected: Bool = true,
                     focus: Bool = true) -> Bool {
            let receipt = BrowserKeyReceipt(context: BrowserPageKeyContext(windowID: self.window, context: captured))
            return BrowserPageKeyContext.accepts(receipt, windowID: window ?? self.window, current: current,
                                                 isKeyWindow: key, isSelected: selected, focusInsideDocument: focus)
        }
        #expect(!accepts(context(revision: 2)), "selection or organization revision changed")
        #expect(!accepts(context(generation: 8)), "another document committed")
        #expect(!accepts(context(surface: nil)), "the surface is no longer selected")
        #expect(!accepts(nil), "the window has no command context")
        #expect(!accepts(captured, window: UUID()), "another window")
        #expect(!accepts(captured, key: false), "the window is no longer key")
        #expect(!accepts(captured, selected: false), "another tab is selected")
        #expect(!accepts(captured, focus: false), "focus left the document")
        let foreign = BrowserKeyReceipt(context: "not a page key context")
        #expect(!BrowserPageKeyContext.accepts(foreign, windowID: window, current: captured, isKeyWindow: true,
                                               isSelected: true, focusInsideDocument: true))
    }
}
}

extension NativeWebKitTests {
@Suite("Shell windows announced to the engine", .serialized)
@MainActor
struct ShellWindowAnnouncementTests {
    @Test("A window's NSWindow is announced before its first placement and released after its surfaces")
    func announcesAndReleases() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SyntheticEngine()
        let environment = BrowserEnvironment<SyntheticEngine>(engine: engine)
        let controller = try await environment.makeWindow()
        controller.submitAddress("https://shell-window.test/")
        await controller.session.waitForPendingCommands()
        let surface = try #require(controller.session.selectedSurface)
        let windowID = try #require(surface.placement.windowID)
        #expect(engine.shellWindows[windowID] == controller.window.map(ObjectIdentifier.init))
        #expect(controller.engineWindowIDs == [windowID])
        controller.window?.close()
        #expect(surface.isDisposed)
        #expect(engine.shellWindows[windowID] == nil)
        #expect(engine.closedShellWindows == [windowID])
        #expect(controller.engineWindowIDs.isEmpty)
    }
}
}
