import BrowserCore
import Foundation

/// Preparation uses a detached session model and a read-only history policy. Asking the live
/// history recorder about a proposed profile resolves its native engine context, creating a
/// directory before Import. Fresh imported profiles are persistent by policy; no engine context
/// needs to exist during review. This target cannot apply or persist anything.
struct BrowserImportReviewTarget: ArcImportTarget {
    let location: ArcImportDataLocation
    private struct ReviewHistory: ArcHistoryImportSink {
        func acceptsHistory(for profileID: ProfileID) async -> Bool { true }
        func beginBulkImport(for profileID: ProfileID) async {}
        func endBulkImport(for profileID: ProfileID) async {}
        func importChunk(_ document: BrowserHistoryDocument) async throws -> Int { throw ArcImportError.targetUnreadable }
    }
    let history: any ArcHistoryImportSink = ReviewHistory()
    let holdsExclusiveAccess = false
    private let store: BrowserStore
    private let document: BrowserSessionDocument
    init(live: ArcImportLiveTarget, document: BrowserSessionDocument) throws {
        location = live.location
        self.document = document
        store = try BrowserStore(restoring: document)
    }
    func defaultProfile() async -> ProfileID? { await store.catalogSnapshot().profiles.first?.id }
    func preview(_ plan: BrowserImportPlan, ledger: BrowserImportLedger) async -> BrowserImportMergeCounts {
        await store.previewImport(plan, ledger: ledger)
    }
    func sessionBackup() async throws -> Data? { try document.encoded() }
    func apply(_ plan: BrowserImportPlan, ledger: BrowserImportLedger) async throws -> BrowserImportMergeResult {
        throw ArcImportError.targetUnreadable
    }
    func persist() async throws { throw ArcImportError.targetUnreadable }
}
