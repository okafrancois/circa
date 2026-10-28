import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("Space profile migration")
struct BrowserSpaceProfileTests {
    @Test("Nested organization, open pages and selection move; Favorites and archive stay with their profiles")
    func preservesContent() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("pinned-one"), b = try await f.open("pinned-two")
        _ = try await f.store.pinTabs([a, b], from: f.context())
        let (split, _) = try await f.store.createSplit([a, b], from: f.context())
        let (folder, _) = try await f.store.createFolder(title: "Synthetic folder", at: .init(.pinned(f.home)),
                                                        containing: [.split(split)], from: f.context())
        _ = try await f.store.createFolder(title: "Synthetic empty child", at: .init(.folder(folder)), from: f.context())
        let today = try await f.open("today")
        let favoriteA = try await f.open("favorite-a")
        _ = try await f.store.addToFavorites([favoriteA], from: f.context())
        let archived = try await f.open("archive")
        _ = try await f.store.archiveTabs([archived], from: f.context())
        try await f.activate(f.lab, in: f.other)
        let favoriteB = try await f.open("favorite-b", in: f.other)
        _ = try await f.store.addToFavorites([favoriteB], from: f.context(f.other))
        try await f.activate(f.home, in: f.other)
        _ = try await f.store.selectTab(today, from: f.context(f.other))
        _ = try await f.store.selectTab(today, from: f.context())
        let context = try await f.context()
        let oldLease = try await f.store.captureOccurrenceAuthority(for: #require(context.selectedOccurrenceID), from: context)
        let before = await f.store.sessionDocument()
        try await f.store.moveSpaceToProfile(f.home, to: f.work, expectedProfileID: f.personal)
        let after = await f.store.sessionDocument()
        try after.validate()
        let expectedArchive = before.organization.archive.map { record in
            var record = record
            if record.spaceID == f.home { record.spaceProfileWasChanged = true }
            return record
        }
        #expect(after.organization.archive == expectedArchive)
        #expect(after.organization.tabs == before.organization.tabs)
        #expect(after.organization.folders == before.organization.folders)
        #expect(after.organization.splits == before.organization.splits)
        #expect(after.organization.spaces == before.organization.spaces)
        #expect(after.organization.favorites == before.organization.favorites)
        #expect(after.spaces.map(\.id) == before.spaces.map(\.id))
        #expect(after.spaces.first { $0.id == f.home }?.profileID == f.work)
        #expect(after.tabs.filter { $0.spaceID == f.home }.allSatisfy { $0.id != favoriteA && $0.id != favoriteB })
        #expect(Set(after.tabs.map(\.occurrenceID)).isDisjoint(with: Set(before.tabs.filter { $0.spaceID == f.home }.map(\.occurrenceID))))
        for window in [f.window, f.other] {
            let state = try await f.store.captureWindowState(in: window)
            #expect(state.context.profileID == f.work)
            #expect(state.snapshot.tabs.first { $0.occurrenceID == state.context.selectedOccurrenceID }?.id == today)
            #expect(state.organization.favorites.map(\.node) == [.tab(favoriteB)])
        }
        await #expect(throws: BrowserStoreError.staleContext) {
            try await f.store.updateDestination(to: organizationURL("stale"), from: oldLease)
        }
        try await f.store.moveSpaceToProfile(f.home, to: f.personal, expectedProfileID: f.work)
        #expect(!(await f.store.isCurrent(context)))
        await #expect(throws: BrowserStoreError.tabMissing) {
            try await f.store.updateDestination(to: organizationURL("aba"), from: oldLease)
        }
        let reopened = try BrowserStore(restoring: BrowserSessionDocument.decode(after.encoded()))
        try await reopened.activateSpace(f.leisure, in: f.window)
        _ = try await reopened.restoreArchivedTab(archived, activate: true, from: reopened.captureContext(in: f.window))
        #expect(try await reopened.snapshot(of: f.window).tabs.contains { $0.id == archived && $0.spaceID == f.leisure })
        try await reopened.sessionDocument().validate()
    }

    @Test("Invalid and stale destinations leave every model byte unchanged; same-profile move is idempotent")
    func admission() async throws {
        let f = try await OrganizationFixture.make()
        _ = try await f.open("retained")
        let before = await f.store.sessionDocument()
        await #expect(throws: BrowserStoreError.profileMissing) {
            try await f.store.moveSpaceToProfile(f.home, to: ProfileID(), expectedProfileID: f.personal)
        }
        await #expect(throws: BrowserStoreError.staleContext) {
            try await f.store.moveSpaceToProfile(f.home, to: f.work, expectedProfileID: f.work)
        }
        try await f.store.moveSpaceToProfile(f.home, to: f.personal, expectedProfileID: f.personal)
        #expect(await f.store.sessionDocument() == before)
        let unused = await f.store.createProfile(name: "Synthetic quarantined")
        _ = try await f.store.reserveSettingsProfileRemoval(unused)
        let reserved = await f.store.sessionDocument()
        await #expect(throws: BrowserSettingsError.profileBeingDeleted) {
            try await f.store.moveSpaceToProfile(f.home, to: unused, expectedProfileID: f.personal)
        }
        #expect(await f.store.sessionDocument() == reserved)
    }

    @Test("The existing session backup retains the pre-move graph in its restorable format")
    func sessionBackup() async throws {
        let root = try canonicalTemporaryDirectory().appendingPathComponent("space-profile-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await OrganizationFixture.make()
        _ = try await f.open("backup-retained")
        let before = await f.store.sessionDocument()
        let location = ArcImportDataLocation(sessionFile: root.appendingPathComponent("session.json"))
        let id = try ArcImportBackups.createSessionBackup(at: location, document: before)
        try await f.store.moveSpaceToProfile(f.home, to: f.work, expectedProfileID: f.personal)
        let saved = try BrowserSessionFileStore().load(from: location.backupsDirectory.appendingPathComponent(id).appendingPathComponent("session.json"))
        #expect(saved == before)
        #expect(ArcImportBackups.manifests(at: location).contains { $0.id == id && $0.sessionPresent })
    }

    @Test("SIGKILL during a profile move save reopens the complete old or new graph", arguments: ["write", "before-rename", "after-rename"])
    func killMidMove(boundary: String) async throws {
        let root = try canonicalTemporaryDirectory().appendingPathComponent("space-profile-kill-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var arguments = Array(CommandLine.arguments.dropFirst())
        if let index = arguments.firstIndex(of: "--filter"), arguments.indices.contains(index + 1) {
            arguments[index + 1] = "BrowserSpaceProfileTests/killWorker"
        } else { arguments += ["--filter", "BrowserSpaceProfileTests/killWorker"] }
        child.arguments = arguments
        child.environment = ProcessInfo.processInfo.environment.merging([
            "ORBIT_SPACE_PROFILE_KILL_ROOT": root.path, "ORBIT_SPACE_PROFILE_KILL_BOUNDARY": boundary
        ]) { _, new in new }
        let output = root.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        child.standardOutput = handle
        child.standardError = handle
        try child.run()
        child.waitUntilExit()
        let workerOutput = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL,
                "Worker exit \(child.terminationStatus), output \(workerOutput)")
        let files = BrowserSessionFileStore()
        let actual = try files.load(from: root.appendingPathComponent("session.json"))
        let expected = try files.load(from: root.appendingPathComponent(boundary == "after-rename" ? "after.json" : "before.json"))
        #expect(actual == expected)
        let restored = try BrowserStore(restoring: actual)
        #expect(await restored.sessionDocument() == actual)
    }

    @Test("Subprocess worker for the interrupted atomic writer")
    func killWorker() async throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_SPACE_PROFILE_KILL_ROOT"],
              let boundary = ProcessInfo.processInfo.environment["ORBIT_SPACE_PROFILE_KILL_BOUNDARY"] else { return }
        let root = URL(fileURLWithPath: path)
        let f = try await OrganizationFixture.make()
        let pinned = try await f.open("retained-pinned")
        _ = try await f.store.pinTabs([pinned], from: f.context())
        _ = try await f.store.createFolder(title: "Retained folder", at: .init(.pinned(f.home)), containing: [.tab(pinned)], from: f.context())
        _ = try await f.open("retained-today")
        let files = BrowserSessionFileStore(), before = await f.store.sessionDocument()
        try files.save(before, to: root.appendingPathComponent("before.json"))
        try files.save(before, to: root.appendingPathComponent("session.json"))
        try await f.store.moveSpaceToProfile(f.home, to: f.work, expectedProfileID: f.personal)
        let after = await f.store.sessionDocument()
        try files.save(after, to: root.appendingPathComponent("after.json"))
        let writer = BrowserSessionFileStore(operations: .init(write: { fd, bytes, count in
            if boundary == "write" {
                _ = Darwin.write(fd, bytes, min(64, count))
                killSpaceProfileWorker()
            }
            return Darwin.write(fd, bytes, count)
        }, replace: { fd, source, target in
            if boundary == "before-rename" { killSpaceProfileWorker() }
            let result = Darwin.renameat(fd, source, fd, target)
            if boundary == "after-rename" { killSpaceProfileWorker() }
            return result
        }))
        try writer.save(after, to: root.appendingPathComponent("session.json"))
        Issue.record("Worker must be killed inside the atomic save")
    }
}

private func canonicalTemporaryDirectory() throws -> URL {
    guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw POSIXError(.EIO) }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}

private func killSpaceProfileWorker() -> Never {
    Darwin.kill(getpid(), SIGKILL)
    // Signal delivery can lag the sending syscall. Never advance to rename while it is pending.
    while true { Darwin.pause() }
}
