import AppKit
import BrowserCore
import BrowserShell
import Foundation
import Testing
import WebKitEngine
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativePersistenceReportingTests {
    @Test("Background errors record diagnostics without presenting a modal and success clears them")
    func backgroundErrorsRemainNonModal() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.configurePersistenceReporting()
        for error in [BrowserSessionError.invalidSelection, .limitExceeded] {
            environment.onPersistenceError?(error)
            #expect(app.backgroundPersistenceDiagnostic == "session.\(error)")
            #expect(NSApp.modalWindow == nil)
            #expect(!app.isPreparingToQuit)
        }
        environment.onPersistenceSuccess?()
        #expect(app.backgroundPersistenceDiagnostic == nil)
    }

    @Test("Diagnostics exclude error descriptions, paths, URLs and userInfo")
    func diagnosticsAreRedacted() {
        let error = NSError(domain: "https://private.example/", code: 13, userInfo: [
            NSLocalizedDescriptionKey: "Private page title",
            NSFilePathErrorKey: "/Users/private/session.json"
        ])
        let diagnostic = OrbitApplication.persistenceDiagnostic(error)
        #expect(diagnostic.contains("code=13"))
        #expect(!diagnostic.contains("private"))
        #expect(!diagnostic.contains("Private page"))
        #expect(OrbitApplication.persistenceDiagnostic(
            BrowserSessionFileError.io(operation: .replaceFile, code: 28))
            .contains("replaceFile"))
    }

    @Test("A failed final save cancels quit, keeps the window usable and permits a later successful quit")
    func failedQuitPreservesWindow() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: "/private/tmp/CircaQuitRetry-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("session.json")
        let environment = try await PreviewEnvironment.open(engine: WebKitBrowserEngine(), sessionFile: destination)
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        defer { app.windows.shutdown() }
        let id = try #require(app.windows.newWindow())
        #expect(await app.windows.waitForPendingCommands(timeout: .seconds(5)))
        let window = try #require(app.windows.windows[id])
        await window.session.waitForPendingCommands()
        try await environment.saveNow()
        let previous = try Data(contentsOf: destination)
        let backup = root.appendingPathComponent("previous.json")
        try FileManager.default.moveItem(at: destination, to: backup)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        await #expect(throws: BrowserSessionFileError.notRegularFile) { try await app.completeTermination() }
        #expect(!app.isPreparingToQuit && !environment.isFinalizing)
        #expect(window.acceptsCommands && !window.session.isClosed)
        #expect(try Data(contentsOf: backup) == previous)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: backup, to: destination)
        try await app.completeTermination()
        #expect(window.session.isClosed)
        #expect(app.windows.windows.isEmpty)
        _ = try BrowserSessionFileStore().load(from: destination)
    }

    @Test("A transient write failure retries without another mutation and preserves the previous file")
    func transientSaveRetries() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/CircaSaveRetry-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("session.json")
        let environment = try await PreviewEnvironment.open(engine: WebKitBrowserEngine(), sessionFile: destination)
        try await environment.saveNow()
        let original = try Data(contentsOf: destination)
        let backup = root.appendingPathComponent("previous.json")
        try FileManager.default.moveItem(at: destination, to: backup)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var failures = 0
        var successes = 0
        environment.onPersistenceError = { _ in
            failures += 1
            #expect((try? Data(contentsOf: backup)) == original)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: backup, to: destination)
        }
        environment.onPersistenceSuccess = { successes += 1 }
        environment.scheduleSave()
        let deadline = ContinuousClock.now + .seconds(5)
        while successes == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(failures == 1)
        #expect(successes == 1)
        let restored = try BrowserSessionFileStore().load(from: destination)
        #expect(restored == (await environment.store.sessionDocument()))
        try await environment.finalize()
    }
}
}
