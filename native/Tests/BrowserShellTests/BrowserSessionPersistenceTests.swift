import BrowserCore
import Darwin
import Foundation
import Testing
import Synchronization
@testable import BrowserShell

@Suite("Automatic session persistence", .timeLimit(.minutes(1)))
struct BrowserSessionPersistenceTests {
    @Test("A late activity veto resumes autosaves after the final document was written")
    func cancelledFinalizationResumesSaving() async throws {
        let directory = try PersistenceTestDirectory()
        let fixture = try await persistenceFixture()
        let persistence = BrowserSessionPersistence(destination: directory.file)
        _ = try await persistence.load()
        _ = try await persistence.finalize(from: fixture.store)
        await persistence.resumeAfterCancelledFinalization()
        try await appendPersistenceTab(to: fixture)
        guard case .saved = try await persistence.saveCurrentState(from: fixture.store) else {
            Issue.record("Cancelled termination must allow subsequent autosaves")
            return
        }
        let expected = await fixture.store.sessionDocument()
        #expect(try BrowserSessionFileStore().load(from: directory.file) == expected)
    }

    @Test("Every accepted save encodes once and writes the same canonical bytes")
    func singleEncoding() async throws {
        let directory = try PersistenceTestDirectory()
        let fixture = try await persistenceFixture()
        let counts = EncodingCounts()
        let persistence = BrowserSessionPersistence(destination: directory.file, fileAccess: .init(encode: {
            counts.encodes.withLock { $0 += 1 }
            return try BrowserSessionFileStore.EncodedDocument($0)
        }, save: { document, url in
            counts.saves.withLock { $0 += 1 }
            return try BrowserSessionFileStore().save(document, to: url)
        }))
        _ = try await persistence.load()
        for _ in 0..<3 {
            let expected = try await fixture.store.sessionDocument().encoded()
            _ = try await persistence.saveCurrentState(from: fixture.store)
            #expect(try Data(contentsOf: directory.file) == expected)
            try await appendPersistenceTab(to: fixture)
        }
        #expect(counts.encodes.withLock { $0 } == 3)
        #expect(counts.saves.withLock { $0 } == 3)
        print("session saves=3 encodes=3 canonicalBytesIdentical=true")
    }

    @Test("Loading a missing file enables real-file autosaves without creating a file on read")
    func autosaveAndLoad() async throws {
        let directory = try PersistenceTestDirectory()
        let destination = directory.root.appendingPathComponent("uncreated/session.json")
        let persistence = BrowserSessionPersistence(destination: destination)
        let fixture = try await persistenceFixture()
        await #expect(throws: BrowserSessionPersistence.PersistenceError.loadRequired) {
            try await persistence.saveCurrentState(from: fixture.store)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        #expect(try await persistence.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        let firstDocument = await fixture.store.sessionDocument()
        let firstResult = try await persistence.saveCurrentState(from: fixture.store)
        guard case .saved(let durability) = firstResult else {
            Issue.record("The first autosave must write a document")
            return
        }
        #expect(durability.didSyncDirectory)
        #expect(try BrowserSessionFileStore().load(from: destination) == firstDocument)

        try await appendPersistenceTab(to: fixture)
        let latestDocument = await fixture.store.sessionDocument()
        let secondResult = try await persistence.saveCurrentState(from: fixture.store)
        guard case .saved = secondResult else {
            Issue.record("A subsequent autosave must replace the document")
            return
        }
        let reader = BrowserSessionPersistence(destination: destination)
        #expect(try await reader.load() == latestDocument)
        let restored = try BrowserStore(restoring: #require(try await reader.load()))
        #expect(await restored.sessionDocument() == latestDocument)
        #expect(latestDocument.windows.count == 2)
        #expect(latestDocument.profiles.count == 2)
        #expect(latestDocument != firstDocument)
    }

    @Test("Finalization preserves saved windows after model teardown and rejects later snapshots")
    func finalizationPreservesWindows() async throws {
        let directory = try PersistenceTestDirectory()
        let snapshots = PersistenceSnapshotCounter()
        let persistence = BrowserSessionPersistence(destination: directory.file, snapshot: { store in
            await snapshots.increment()
            return await store.sessionDocument()
        })
        let fixture = try await persistenceFixture()
        #expect(try await persistence.load() == nil)
        try await persistence.saveCurrentState(from: fixture.store)
        try await appendPersistenceTab(to: fixture)
        let expected = await fixture.store.sessionDocument()
        guard case .saved = try await persistence.finalize(from: fixture.store) else {
            Issue.record("Finalization must save the final current document")
            return
        }
        for window in expected.windows { try await fixture.store.closeWindow(window.id) }
        #expect(await fixture.store.sessionDocument().windows.isEmpty)
        #expect(try await persistence.saveCurrentState(from: fixture.store) == .stopped)
        #expect(try await persistence.finalize(from: fixture.store) == .stopped)
        #expect(try await persistence.load() == expected)
        #expect(try await persistence.saveCurrentState(from: fixture.store) == .stopped)
        #expect(await snapshots.count == 2)
        #expect(try BrowserSessionFileStore().load(from: directory.file) == expected)
    }

    @Test("Corrupt input is surfaced and cannot be overwritten by autosave or finalization")
    func corruptInputRemainsUntouched() async throws {
        let directory = try PersistenceTestDirectory()
        let bytes = Data("{incomplete synthetic session".utf8)
        try bytes.write(to: directory.file)
        let persistence = BrowserSessionPersistence(destination: directory.file)
        let fixture = try await persistenceFixture()
        await #expect(throws: BrowserSessionFileError.corruptDocument) { try await persistence.load() }
        await #expect(throws: BrowserSessionPersistence.PersistenceError.loadRequired) {
            try await persistence.saveCurrentState(from: fixture.store)
        }
        await #expect(throws: BrowserSessionPersistence.PersistenceError.loadRequired) {
            try await persistence.finalize(from: fixture.store)
        }
        #expect(try Data(contentsOf: directory.file) == bytes)

        // Explicit caller recovery, outside the coordinator, permits a later load and save.
        try FileManager.default.moveItem(at: directory.file, to: directory.root.appendingPathComponent("recovered.json"))
        #expect(try await persistence.load() == nil)
        try await persistence.saveCurrentState(from: fixture.store)
        let recovered = await fixture.store.sessionDocument()
        #expect(try BrowserSessionFileStore().load(from: directory.file) == recovered)
        #expect(try Data(contentsOf: directory.root.appendingPathComponent("recovered.json")) == bytes)
    }

    @Test("Unsupported document versions remain errors and are never treated as a missing file")
    func unsupportedVersionIsSurfaced() async throws {
        let directory = try PersistenceTestDirectory()
        let document = BrowserSessionDocument(version: BrowserSessionDocument.currentVersion + 1, profiles: [], spaces: [], windows: [], tabs: [])
        let bytes = try JSONEncoder().encode(document)
        try bytes.write(to: directory.file)
        let persistence = BrowserSessionPersistence(destination: directory.file)
        await #expect(throws: BrowserSessionError.unsupportedVersion) { try await persistence.load() }
        await #expect(throws: BrowserSessionPersistence.PersistenceError.loadRequired) {
            try await persistence.saveCurrentState(from: BrowserStore())
        }
        #expect(try Data(contentsOf: directory.file) == bytes)
    }

    @Test("Reload errors disable previously enabled autosaves without replacing the invalid input")
    func reloadFailureDisablesSaving() async throws {
        let directory = try PersistenceTestDirectory()
        let fixture = try await persistenceFixture()
        let persistence = BrowserSessionPersistence(destination: directory.file)
        #expect(try await persistence.load() == nil)
        try await persistence.saveCurrentState(from: fixture.store)
        let corrupt = Data("corrupt synthetic replacement".utf8)
        try corrupt.write(to: directory.file)
        await #expect(throws: BrowserSessionFileError.corruptDocument) { try await persistence.load() }
        await #expect(throws: BrowserSessionPersistence.PersistenceError.loadRequired) {
            try await persistence.saveCurrentState(from: fixture.store)
        }
        #expect(try Data(contentsOf: directory.file) == corrupt)
    }

    @Test("Real path errors are surfaced without replacing the obstructing file")
    func realFileErrors() async throws {
        let directory = try PersistenceTestDirectory()
        let obstruction = directory.root.appendingPathComponent("blocked")
        let destination = obstruction.appendingPathComponent("session.json")
        let fixture = try await persistenceFixture()
        let persistence = BrowserSessionPersistence(destination: destination)
        #expect(try await persistence.load() == nil)
        let bytes = Data("synthetic path obstruction".utf8)
        try bytes.write(to: obstruction)
        await #expect(throws: BrowserSessionFileError.notDirectory) {
            try await persistence.saveCurrentState(from: fixture.store)
        }
        await #expect(throws: BrowserSessionFileError.notDirectory) {
            try await persistence.finalize(from: fixture.store)
        }
        #expect(try Data(contentsOf: obstruction) == bytes)
        try FileManager.default.removeItem(at: obstruction)
        guard case .saved = try await persistence.finalize(from: fixture.store) else {
            Issue.record("A final save must be retryable after the path is repaired")
            return
        }
        let expected = await fixture.store.sessionDocument()
        #expect(try BrowserSessionFileStore().load(from: destination) == expected)
    }

    @Test("One byte budget admits reads and writes, retains prior bytes on oversize, and permits final-save retry")
    func oversizeDocumentsRemainRetryable() async throws {
        let directory = try PersistenceTestDirectory()
        let fixture = try await persistenceFixture()
        let original = await fixture.store.sessionDocument()
        let originalBytes = try original.encoded()
        let persistence = BrowserSessionPersistence(destination: directory.file, maximumBytes: originalBytes.count)
        #expect(try await persistence.load() == nil)
        try await persistence.saveCurrentState(from: fixture.store)
        #expect(try Data(contentsOf: directory.file) == originalBytes)
        let exactReader = BrowserSessionPersistence(destination: directory.file, maximumBytes: originalBytes.count)
        #expect(try await exactReader.load() == original)
        let smallerReader = BrowserSessionPersistence(destination: directory.file, maximumBytes: originalBytes.count - 1)
        await #expect(throws: BrowserSessionError.limitExceeded) { try await smallerReader.load() }

        try await appendPersistenceTab(to: fixture)
        await #expect(throws: BrowserSessionError.limitExceeded) {
            try await persistence.saveCurrentState(from: fixture.store)
        }
        #expect(try Data(contentsOf: directory.file) == originalBytes)
        await #expect(throws: BrowserSessionError.limitExceeded) {
            try await persistence.finalize(from: fixture.store)
        }
        #expect(try Data(contentsOf: directory.file) == originalBytes)
        let context = try await fixture.store.captureContext(in: fixture.windowID)
        try await fixture.store.closeOccurrence(#require(context.selectedOccurrenceID), from: context)
        // Closing a Today tab archives it; deleting that record shrinks the document back.
        let closedContext = try await fixture.store.captureContext(in: fixture.windowID)
        let archived = try await fixture.store.archivedTabs(from: closedContext)
        _ = try await fixture.store.deleteArchivedTabs(archived.map(\.id), from: closedContext)
        guard case .saved = try await persistence.finalize(from: fixture.store) else {
            Issue.record("An oversize final-save failure must permit a smaller final-save retry")
            return
        }
        #expect(try await persistence.load() == original)
        #expect(try Data(contentsOf: directory.file) == originalBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.root.path) == ["session.json"])
    }

    @Test("Oversize output cannot create even an empty destination directory")
    func oversizeOutputDoesNotTouchFilesystem() async throws {
        let directory = try PersistenceTestDirectory()
        let destination = directory.root.appendingPathComponent("uncreated/session.json")
        let persistence = BrowserSessionPersistence(destination: destination, maximumBytes: 0)
        #expect(try await persistence.load() == nil)
        await #expect(throws: BrowserSessionError.limitExceeded) {
            try await persistence.saveCurrentState(from: BrowserStore())
        }
        await #expect(throws: BrowserSessionError.limitExceeded) {
            try await persistence.finalize(from: BrowserStore())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.root.path).isEmpty)
    }

    @Test("A failed final write preserves prior bytes and permits autosave, retry, and cancellation of quitting")
    func failedFinalizationCanRetry() async throws {
        let directory = try PersistenceTestDirectory()
        let fixture = try await persistenceFixture()
        let failures = PersistenceFailureSwitch()
        let persistence = BrowserSessionPersistence(destination: directory.file, fileAccess: .init(save: { document, url in
            if failures.isEnabled { throw BrowserSessionFileError.io(operation: .writeTemporaryFile, code: EIO) }
            return try BrowserSessionFileStore().save(document, to: url)
        }))
        #expect(try await persistence.load() == nil)
        try await persistence.saveCurrentState(from: fixture.store)
        let original = try Data(contentsOf: directory.file)
        try await appendPersistenceTab(to: fixture)
        failures.isEnabled = true
        await #expect(throws: BrowserSessionFileError.io(operation: .writeTemporaryFile, code: EIO)) {
            try await persistence.finalize(from: fixture.store)
        }
        #expect(try Data(contentsOf: directory.file) == original)
        #expect(await fixture.store.sessionDocument().windows.count == 2)
        failures.isEnabled = false
        guard case .saved = try await persistence.saveCurrentState(from: fixture.store) else {
            Issue.record("Cancelling a failed quit must leave autosaving enabled")
            return
        }
        try await appendPersistenceTab(to: fixture)
        let final = await fixture.store.sessionDocument()
        guard case .saved = try await persistence.finalize(from: fixture.store) else {
            Issue.record("A failed final save must not permanently stop the coordinator")
            return
        }
        #expect(try BrowserSessionFileStore().load(from: directory.file) == final)
    }

    @Test("A post-replacement final-save error stays visible and stale snapshots cannot replace its document")
    func failureAfterReplacementDoesNotReviveOlderSnapshots() async throws {
        let directory = try PersistenceTestDirectory()
        let fixture = try await persistenceFixture()
        let gate = PersistenceSnapshotGate()
        let counter = PersistenceSnapshotCounter()
        let failures = PersistenceFailureSwitch()
        let persistence = BrowserSessionPersistence(destination: directory.file, snapshot: { store in
            let document = await store.sessionDocument()
            if await counter.increment() == 1 { await gate.pause() }
            return document
        }, fileAccess: .init(save: { document, url in
            let result = try BrowserSessionFileStore().save(document, to: url)
            if failures.isEnabled { throw BrowserSessionFileError.replacedButDirectorySyncFailed(code: EIO) }
            return result
        }))
        #expect(try await persistence.load() == nil)
        let oldSave = Task { try await persistence.saveCurrentState(from: fixture.store) }
        await gate.waitForArrival()
        try await appendPersistenceTab(to: fixture)
        let replaced = await fixture.store.sessionDocument()
        failures.isEnabled = true
        await #expect(throws: BrowserSessionFileError.replacedButDirectorySyncFailed(code: EIO)) {
            try await persistence.finalize(from: fixture.store)
        }
        #expect(try BrowserSessionFileStore().load(from: directory.file) == replaced)
        await gate.release()
        #expect(try await oldSave.value == .superseded)
        #expect(try BrowserSessionFileStore().load(from: directory.file) == replaced)
        failures.isEnabled = false
        try await appendPersistenceTab(to: fixture)
        let expected = await fixture.store.sessionDocument()
        guard case .saved = try await persistence.finalize(from: fixture.store) else {
            Issue.record("Even a post-replacement failure must permit a final-save retry")
            return
        }
        #expect(try BrowserSessionFileStore().load(from: directory.file) == expected)
    }

    @Test("A delayed older snapshot cannot overwrite a newer completed autosave")
    func snapshotReentrancyKeepsNewestSave() async throws {
        let directory = try PersistenceTestDirectory()
        let fixture = try await persistenceFixture()
        let gate = PersistenceSnapshotGate()
        let counter = PersistenceSnapshotCounter()
        let persistence = BrowserSessionPersistence(destination: directory.file, snapshot: { store in
            let document = await store.sessionDocument()
            if await counter.increment() == 1 { await gate.pause() }
            return document
        })
        #expect(try await persistence.load() == nil)
        let oldSave = Task { try await persistence.saveCurrentState(from: fixture.store) }
        await gate.waitForArrival()
        try await appendPersistenceTab(to: fixture)
        let expected = await fixture.store.sessionDocument()
        guard case .saved = try await persistence.saveCurrentState(from: fixture.store) else {
            await gate.release()
            Issue.record("The newer snapshot must be saved while the older snapshot is suspended")
            return
        }
        await gate.release()
        #expect(try await oldSave.value == .superseded)
        #expect(try BrowserSessionFileStore().load(from: directory.file) == expected)
    }

    @Test("Finalization supersedes pending autosaves even if their snapshots return after window teardown")
    func finalizationSupersedesOutstandingSnapshot() async throws {
        let directory = try PersistenceTestDirectory()
        let fixture = try await persistenceFixture()
        let gate = PersistenceSnapshotGate()
        let counter = PersistenceSnapshotCounter()
        let persistence = BrowserSessionPersistence(destination: directory.file, snapshot: { store in
            let document = await store.sessionDocument()
            if await counter.increment() == 1 { await gate.pause() }
            return document
        })
        #expect(try await persistence.load() == nil)
        let oldSave = Task { try await persistence.saveCurrentState(from: fixture.store) }
        await gate.waitForArrival()
        try await appendPersistenceTab(to: fixture)
        let final = await fixture.store.sessionDocument()
        try await persistence.finalize(from: fixture.store)
        for window in final.windows { try await fixture.store.closeWindow(window.id) }
        await gate.release()
        #expect(try await oldSave.value == .superseded)
        #expect(try await persistence.saveCurrentState(from: fixture.store) == .stopped)
        #expect(try BrowserSessionFileStore().load(from: directory.file) == final)
    }

    @Test("Finalization closes the save gate before awaiting its snapshot")
    func finalizationGatesConcurrentRequests() async throws {
        let directory = try PersistenceTestDirectory()
        let fixture = try await persistenceFixture()
        let gate = PersistenceSnapshotGate()
        let counter = PersistenceSnapshotCounter()
        let persistence = BrowserSessionPersistence(destination: directory.file, snapshot: { store in
            await counter.increment()
            let document = await store.sessionDocument()
            await gate.pause()
            return document
        })
        #expect(try await persistence.load() == nil)
        let finalSave = Task { try await persistence.finalize(from: fixture.store) }
        await gate.waitForArrival()
        #expect(try await persistence.saveCurrentState(from: fixture.store) == .stopped)
        await #expect(throws: BrowserSessionPersistence.PersistenceError.finalizationInProgress) {
            try await persistence.finalize(from: fixture.store)
        }
        await #expect(throws: BrowserSessionPersistence.PersistenceError.finalizationInProgress) {
            try await persistence.load()
        }
        #expect(await counter.count == 1)
        await gate.release()
        guard case .saved = try await finalSave.value else {
            Issue.record("The original finalization must finish its write")
            return
        }
    }

    @Test("Reload invalidates an older suspended snapshot")
    func reloadSupersedesOutstandingSnapshot() async throws {
        let directory = try PersistenceTestDirectory()
        let fixture = try await persistenceFixture()
        let gate = PersistenceSnapshotGate()
        let persistence = BrowserSessionPersistence(destination: directory.file, snapshot: { store in
            let document = await store.sessionDocument()
            await gate.pause()
            return document
        })
        #expect(try await persistence.load() == nil)
        let save = Task { try await persistence.saveCurrentState(from: fixture.store) }
        await gate.waitForArrival()
        #expect(try await persistence.load() == nil)
        await gate.release()
        #expect(try await save.value == .superseded)
        #expect(!FileManager.default.fileExists(atPath: directory.file.path))
    }

    @Test("File work stays off the main thread and a blocked write does not block newer snapshots")
    @MainActor
    func fileWorkIsOffMainAndSerialized() async throws {
        let directory = try PersistenceTestDirectory()
        let fixture = try await persistenceFixture()
        let probe = PersistenceFileProbe()
        let releaseWrite = DispatchSemaphore(value: 0)
        let (arrivals, continuation) = AsyncStream<Void>.makeStream()
        let counter = PersistenceSnapshotCounter()
        let persistence = BrowserSessionPersistence(destination: directory.file, snapshot: { store in
            let document = await store.sessionDocument()
            await counter.increment()
            return document
        }, fileAccess: .init(load: { url, maximumBytes in
            probe.begin()
            defer { probe.end() }
            return try BrowserSessionFileStore().load(from: url, maximumBytes: maximumBytes)
        }, save: { document, url in
            let shouldBlock = probe.beginWrite()
            defer { probe.end() }
            if shouldBlock {
                continuation.yield(())
                guard releaseWrite.wait(timeout: .now() + 10) == .success else { throw PersistenceTestError.timeout }
            }
            return try BrowserSessionFileStore().save(document, to: url)
        }))
        defer { releaseWrite.signal(); continuation.finish() }
        #expect(try await persistence.load() == nil)
        let firstSave = Task { try await persistence.saveCurrentState(from: fixture.store) }
        var iterator = arrivals.makeAsyncIterator()
        _ = await iterator.next()
        try await appendPersistenceTab(to: fixture)
        let expected = await fixture.store.sessionDocument()
        let secondSave = Task { try await persistence.saveCurrentState(from: fixture.store) }
        await counter.waitForCount(2)
        #expect(probe.observations.active == 1)
        releaseWrite.signal()
        guard case .saved = try await firstSave.value, case .saved = try await secondSave.value else {
            Issue.record("Both ordered writes must finish")
            return
        }
        #expect(probe.observations.maximumActive == 1)
        #expect(!probe.observations.observedMainThread)
        #expect(probe.observations.active == 0)
        #expect(try BrowserSessionFileStore().load(from: directory.file) == expected)
    }
}

private enum PersistenceTestError: Error { case timeout }

private final class PersistenceTestDirectory {
    let root: URL
    var file: URL { root.appendingPathComponent("session.json") }

    init() throws {
        // /private avoids the /var symlink rejected by the production file store.
        root = URL(fileURLWithPath: "/private/tmp/orbit-persistence-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private struct PersistenceFixture: Sendable {
    let store: BrowserStore
    let windowID: WindowID
}

private func persistenceFixture() async throws -> PersistenceFixture {
    // A fixed clock keeps viewing timestamps, and therefore document bytes, reproducible.
    let store = BrowserStore(clock: { Date(timeIntervalSinceReferenceDate: 800_000_000) })
    let firstProfile = await store.createProfile(name: "Synthetic work")
    let firstSpace = try await store.createSpace(name: "Synthetic main", profileID: firstProfile)
    let secondSpace = try await store.createSpace(name: "Synthetic secondary", profileID: firstProfile)
    let firstWindow = try await store.createWindow(activeSpaceID: firstSpace)
    var context = try await store.captureContext(in: firstWindow)
    try await store.openTab(url: URL(string: "https://first.example.test")!, from: context, activate: true)
    try await store.activateSpace(secondSpace, in: firstWindow)
    context = try await store.captureContext(in: firstWindow)
    try await store.openTab(url: URL(string: "about:blank")!, from: context, activate: true)
    try await store.activateSpace(firstSpace, in: firstWindow)
    let secondProfile = await store.createProfile(name: "Synthetic personal")
    let otherSpace = try await store.createSpace(name: "Synthetic empty", profileID: secondProfile)
    try await store.createWindow(activeSpaceID: otherSpace)
    return PersistenceFixture(store: store, windowID: firstWindow)
}

private func appendPersistenceTab(to fixture: PersistenceFixture) async throws {
    let context = try await fixture.store.captureContext(in: fixture.windowID)
    try await fixture.store.openTab(url: URL(string: "https://newer.example.test")!, from: context, activate: true)
}

private actor PersistenceSnapshotGate {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        arrived = true
        for continuation in arrivals { continuation.resume() }
        arrivals.removeAll()
        if !released { await withCheckedContinuation { releases.append($0) } }
    }

    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrivals.append($0) } }
    }

    func release() {
        released = true
        for continuation in releases { continuation.resume() }
        releases.removeAll()
    }
}

private actor PersistenceSnapshotCounter {
    private(set) var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    @discardableResult
    func increment() -> Int {
        count += 1
        for (target, continuation) in waiters where count >= target { continuation.resume() }
        waiters.removeAll { count >= $0.0 }
        return count
    }

    func waitForCount(_ target: Int) async {
        if count < target { await withCheckedContinuation { waiters.append((target, $0)) } }
    }
}

private final class PersistenceFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isEnabled: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class PersistenceFileProbe: @unchecked Sendable {
    struct Observations {
        var active = 0
        var maximumActive = 0
        var observedMainThread = false
    }

    private let lock = NSLock()
    private var value = Observations()
    private var writes = 0
    var observations: Observations { lock.withLock { value } }

    func begin() {
        lock.withLock { recordStart() }
    }

    func beginWrite() -> Bool {
        lock.withLock {
            recordStart()
            writes += 1
            return writes == 1
        }
    }

    func end() { lock.withLock { value.active -= 1 } }

    private func recordStart() {
        value.active += 1
        value.maximumActive = max(value.maximumActive, value.active)
        value.observedMainThread = value.observedMainThread || Thread.isMainThread
    }
}

private final class EncodingCounts: Sendable {
    let encodes = Mutex(0)
    let saves = Mutex(0)
}
