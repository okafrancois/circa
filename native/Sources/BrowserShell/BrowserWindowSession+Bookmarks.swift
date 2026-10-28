import BrowserCore
import Foundation

/// The same pending/revoked/admitted contract used by catalog presentations;
/// each import owns a distinct token. Admission wins once at the store boundary.
public typealias BrowserBookmarkImportAdmission = CatalogSelectionAdmission

private extension BrowserStore {
    func importCapturedBookmarks(_ document: BrowserBookmarkDocument, title: String, from expected: BrowserContext,
                                 labels: BrowserBookmarkLabels, admission: BrowserBookmarkImportAdmission) throws -> (FolderID, BrowserWindowState) {
        guard try captureContext(in: expected.windowID) == expected, admission.admit() else {
            throw BrowserStoreError.staleContext
        }
        return try importBookmarks(document, folderTitle: title, from: expected, labels: labels)
    }
}

public extension BrowserWindowSession {
    /// File choices and parsing begin before model admission; retirement must
    /// also finish those presentations, including direct session retirement.
    func registerBookmarkTransferCancellation(_ cancel: @escaping @MainActor () -> Void) -> UUID? {
        guard !isClosed else { return nil }
        let id = UUID()
        bookmarkTransferCancellations[id] = cancel
        return id
    }

    func removeBookmarkTransferCancellation(_ id: UUID) { bookmarkTransferCancellations[id] = nil }

    /// A deliberate Save has already accepted this standalone file write. It
    /// survives source closure and joins Quit draining without serializing later
    /// navigation behind slow file I/O.
    func finishAcceptedBookmarkExport(_ write: @escaping @Sendable () async throws -> Void) async throws {
        let id = UUID()
        let operation = Task { @MainActor [self] in
            defer { acceptedBookmarkExports.removeValue(forKey: id) }
            try await write()
        }
        acceptedBookmarkExports[id] = operation
        try await operation.value
    }

    func exportBookmarks(from expected: BrowserContext, labels: BrowserBookmarkLabels = .init()) -> Task<BrowserBookmarkDocument?, Never> {
        guard !isClosed else { return Task { nil } }
        pendingCommandCount += 1
        let previous = pending
        let task = Task<BrowserBookmarkDocument?, Never> { [self] in
            defer { pendingCommandCount -= 1 }
            await previous?.value
            guard !isClosed else { return nil }
            do {
                guard try await organizationContext() == expected else { throw BrowserStoreError.staleContext }
                return try await store.exportBookmarks(from: expected, labels: labels)
            } catch {
                if !isClosed { onError?(error) }
                return nil
            }
        }
        pending = Task { _ = await task.value }
        return task
    }

    /// File parsing/confirmation cannot recapture a different target after an
    /// await. The original context and revocable token accompany the one commit.
    @discardableResult
    func importBookmarks(_ document: BrowserBookmarkDocument, title: String, from expected: BrowserContext,
                         labels: BrowserBookmarkLabels = .init(),
                         admission: BrowserBookmarkImportAdmission) -> Task<FolderID?, Never> {
        guard !isClosed else { admission.revoke(); return Task { nil } }
        let requestID = UUID()
        bookmarkAdmissions[requestID] = admission
        pendingCommandCount += 1
        let previous = pending
        let task = Task<FolderID?, Never> { [self] in
            defer {
                pendingCommandCount -= 1
                bookmarkAdmissions[requestID] = nil
                admission.revoke()
            }
            await previous?.value
            guard !isClosed, admission.state == .pending else { return nil }
            do {
                guard try await organizationContext() == expected else { throw BrowserStoreError.staleContext }
                let (id, state) = try await store.importCapturedBookmarks(document, title: title, from: expected,
                                                                        labels: labels, admission: admission)
                if !isClosed { install(state) }
                // Retain the actual commit result even if presentation closes
                // afterward. Cancellation never pretends an admitted write was undone.
                return id
            } catch {
                admission.revoke()
                if !isClosed, !(error is CancellationError) { onError?(error) }
                return nil
            }
        }
        pending = Task { _ = await task.value }
        return task
    }
}
