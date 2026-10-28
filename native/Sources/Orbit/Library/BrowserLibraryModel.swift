import BrowserCore
import Foundation

/// Orbit Library destinations. History remains available from its separate menu command.
enum BrowserLibraryCategory: Int, CaseIterable {
    case downloads, history, archive, spaces, media
    var title: String {
        switch self {
        case .downloads: return libraryText("downloads", "Downloads")
        case .history: return libraryText("history", "History")
        case .archive: return libraryText("archive", "Archived Tabs")
        case .spaces: return libraryText("spaces", "Spaces")
        case .media: return uiText("Media")
        }
    }
    static let railCategories: [Self] = [.media, .downloads, .spaces, .archive]
    var symbol: String {
        switch self {
        case .media: "photo.on.rectangle"
        case .downloads: "arrow.down.circle"
        case .spaces: "rectangle.on.rectangle"
        case .archive: "archivebox"
        case .history: "clock"
        }
    }
}

@MainActor
final class BrowserLibraryHistoryModel {
    var recorder = BrowserHistoryRecorder()
    private(set) var profileID: ProfileID?
    private(set) var visits: [BrowserHistoryVisit] = []
    private(set) var query = ""
    private(set) var displayedQuery = ""
    private(set) var isDebouncing = false
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var hasError = false
    private var generation = UUID()
    private var nextOffset = 0
    private(set) var task: Task<Void, Never>?
    var onChange: (() -> Void)?
    let pageSize = 200

    func selectProfile(_ profile: ProfileID?) {
        guard profileID != profile else { return }
        invalidate()
        profileID = profile
        query = ""
        reload()
    }

    func search(_ query: String) {
        guard self.query != query else { return }
        self.query = query
        load(reset: true, debounce: true)
    }

    func reload() { load(reset: true) }
    func loadMore() { guard hasMore, !isLoading else { return }; load(reset: false) }
    func stop() {
        guard profileID != nil || task != nil else { return }
        invalidate(); profileID = nil; onChange?()
    }

    private func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        visits = []
        displayedQuery = ""
        isDebouncing = false
        nextOffset = 0
        hasMore = false
        hasError = false
        isLoading = false
    }

    private func load(reset: Bool, debounce: Bool = false, preservingCount: Bool = false) {
        task?.cancel()
        generation = UUID()
        let token = generation
        guard let profile = profileID else { onChange?(); return }
        let query = query
        let offset = reset ? 0 : nextOffset
        let limit = preservingCount ? min(10_000, max(pageSize, visits.count)) : pageSize
        isLoading = true
        isDebouncing = debounce
        hasError = false
        onChange?()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(120)) }
                try Task.checkCancellation()
                guard generation == token, profileID == profile else { return }
                if isDebouncing { isDebouncing = false; onChange?() }
                await recorder.flush()
                guard !Task.isCancelled, generation == token, profileID == profile else { return }
                let page = try await recorder.visits(for: profile, search: query, limit: limit, offset: offset)
                guard !Task.isCancelled, generation == token, profileID == profile else { return }
                // Track database rows consumed separately from unique UI rows. New visits before
                // an OFFSET boundary may repeat rows, but can never duplicate a displayed ID.
                nextOffset = offset + page.count
                var known = Set(reset ? [] : visits.map(\.id))
                let unique = page.filter { known.insert($0.id).inserted }
                visits = reset ? unique : visits + unique
                displayedQuery = query
                hasMore = page.count == limit
            } catch {
                guard !Task.isCancelled, generation == token, profileID == profile else { return }
                hasError = true
            }
            isLoading = false
            onChange?()
        }
    }

    /// A stale UI cannot delete from the newly selected profile. Deletions drain queued writes
    /// in the recorder, then retain the loaded window and its scroll anchor during refresh.
    @discardableResult
    func delete(_ deletion: BrowserHistoryDeletion, in profile: ProfileID) async -> Bool {
        guard profileID == profile else { return false }
        let token = generation
        do {
            _ = try await recorder.delete(for: profile, deletion)
            guard profileID == profile else { return true }
            load(reset: true, preservingCount: true)
            await task?.value
            return true
        } catch {
            if profileID == profile, generation == token { hasError = true; onChange?() }
            return false
        }
    }
}
