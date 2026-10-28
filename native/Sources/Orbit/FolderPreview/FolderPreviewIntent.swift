import AppKit
import BrowserCore

/// Reconstruction defaults, not measured Orbit timings or recursive presentation semantics.
@MainActor
final class FolderPreviewIntent {
    enum Phase { case idle, armed, visible, leaving }
    private(set) var phase: Phase = .idle
    private(set) var epoch: UInt64 = 0
    private(set) var admission = BrowserSidebarSelectionAdmission()
    private(set) var snapshot: BrowserOrganizationSnapshot?
    private(set) var folder: FolderID?
    private(set) var results: [FolderPreviewResult] = []
    private(set) var isDismissingAfterDeparture = false
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> any OrbitCancellable = {
        OrbitRunLoopTimer(after: $0, $1)
    }
    var validate: () -> Bool = { true }
    var onShow: (() -> Void)?
    var onHide: (() -> Void)?
    var onResults: (() -> Void)?
    private var timer: (any OrbitCancellable)?
    private var searchTimer: (any OrbitCancellable)?
    private var searchEpoch: UInt64 = 0
    private var departureEpoch: UInt64 = 0

    func arm(folder: FolderID, snapshot: BrowserOrganizationSnapshot) {
        revoke()
        guard case .folder? = snapshot.item(for: .folder(folder)) else { return }
        admission = BrowserSidebarSelectionAdmission()
        self.folder = folder
        self.snapshot = snapshot
        phase = .armed
        let token = epoch
        timer = schedule(0.300) { [weak self] in
            guard let self, self.epoch == token, self.validate() else { return }
            self.phase = .visible
            self.results = self.allResults
            self.onShow?()
        }
    }

    func departure() {
        if phase == .armed { revoke(); return }
        guard phase == .visible else { return }
        phase = .leaving
        departureEpoch &+= 1
        let token = epoch, departure = departureEpoch
        timer = schedule(0.180) { [weak self] in
            guard let self, self.epoch == token, self.departureEpoch == departure, self.phase == .leaving else { return }
            self.isDismissingAfterDeparture = true
            self.revoke()
            self.isDismissingAfterDeparture = false
        }
    }

    func returnToPreview() {
        guard phase == .leaving else { return }
        departureEpoch &+= 1
        timer?.cancel(); timer = nil
        phase = .visible
    }

    func search(_ query: String) {
        returnToPreview()
        admission.revoke()
        admission = BrowserSidebarSelectionAdmission()
        epoch &+= 1 // Every search retires queued actions from the previous result set.
        searchTimer?.cancel()
        searchEpoch &+= 1
        results = [] // Old rows become inert immediately, including during IME composition.
        onResults?()
        let token = epoch, request = searchEpoch
        let term = String(query.prefix(500))
        searchTimer = schedule(0.100) { [weak self] in
            guard let self, self.epoch == token, self.searchEpoch == request,
                  self.phase != .idle, self.validate() else { return }
            self.results = self.allResults.filter { term.isEmpty ||
                ($0.title + " " + $0.path.joined(separator: " ")).range(of: term,
                    options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            self.onResults?()
        }
    }

    func permits(_ id: TabID, epoch: UInt64, current: BrowserOrganizationSnapshot?) -> Bool {
        self.epoch == epoch && phase != .idle && current == snapshot && validate()
            && results.contains { $0.tab.id == id }
    }

    func reconcile(_ current: BrowserOrganizationSnapshot?) {
        if snapshot != nil, snapshot != current { revoke() }
    }

    func revoke() {
        admission.revoke()
        epoch &+= 1; searchEpoch &+= 1; departureEpoch &+= 1
        timer?.cancel(); timer = nil
        searchTimer?.cancel(); searchTimer = nil
        phase = .idle; snapshot = nil; folder = nil; results = []
        onHide?()
    }

    var allResults: [FolderPreviewResult] {
        guard let snapshot, let folder, case let .folder(root)? = snapshot.item(for: .folder(folder)) else { return [] }
        return FolderPreviewResult.ordered(root.children)
    }
}

struct FolderPreviewResult {
    let tab: BrowserOrganizationTabItem
    let path: [String]
    let split: SplitGroupID?
    var title: String { tab.title?.isEmpty == false ? tab.title! : (tab.url.host ?? tab.url.absoluteString) }

    /// Depth-first traversal is a reconstruction choice; split panes retain their stored order.
    static func ordered(_ items: [BrowserOrganizationItem], path: [String] = []) -> [Self] {
        items.flatMap { item -> [Self] in
            switch item {
            case let .tab(tab): return [.init(tab: tab, path: path, split: nil)]
            case let .folder(folder): return ordered(folder.children, path: path + [folder.title])
            case let .split(split): return split.tabs.map { .init(tab: $0, path: path, split: split.group.id) }
            }
        }
    }
}
