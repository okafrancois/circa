import AppKit
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Existing-directory chooser", .serialized)
@MainActor
struct ExistingDirectoryChooserTests {
    @Test("Directory selection returns without upload confirmation and preserves cancellation")
    func existingDirectoryDoesNotUpload() async throws {
        let presenter = BrowserFileChooserPresenter()
        let view = NSView()
        let surface = ObjectIdentifier(view)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.resolvingSymlinksInPath().standardizedFileURL
        let alias = root.appendingPathComponent("directory-link")
        let target = root.appendingPathComponent("extension", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        presenter.responder = { _ in [folder] }
        #expect(await presenter.run(.init(mode: .openExistingFolder), on: view, surface: surface) == [folder])
        #expect(BrowserPageDialogCenter.shared.presentedDialog(for: surface) == nil)
        presenter.responder = { _ in [alias] }
        #expect(await presenter.run(.init(mode: .openExistingFolder), on: view, surface: surface) == [target])
        presenter.responder = { _ in [folder, target] }
        #expect(await presenter.run(.init(mode: .openExistingFolder), on: view, surface: surface) == nil)
        let file = root.appendingPathComponent("manifest.json")
        try Data("{}".utf8).write(to: file)
        presenter.responder = { _ in [file] }
        #expect(await presenter.run(.init(mode: .openExistingFolder), on: view, surface: surface) == nil)
        presenter.responder = { _ in [URL(string: "https://synthetic.invalid/")!] }
        #expect(await presenter.run(.init(mode: .openExistingFolder), on: view, surface: surface) == nil)
        presenter.responder = { _ in nil }
        #expect(await presenter.run(.init(mode: .openExistingFolder), on: view, surface: surface) == nil)
        presenter.responder = { _ in [] }
        #expect(await presenter.run(.init(mode: .openExistingFolder), on: view, surface: surface) == nil)
    }
}
}
