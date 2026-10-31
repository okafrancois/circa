import AppKit
import BrowserCore
import BrowserEngine
import Combine

/// One settings authority for all windows of an environment. Refreshes publish only after the
/// durable actor commits, and controls enqueue full mutations instead of overwriting stale forms.
@MainActor
final class BrowserSettingsRuntime: ObservableObject {
    let updater = OrbitUpdater()
    let feedback = OrbitInteractionFeedback()
    let store: BrowserSettingsStore
    @Published private(set) var document = BrowserSettingsDocument()
    var onChange: (() -> Void)?
    var isUnavailable: Bool { store.isUnavailable }
    private var extensionPinSaves: [ProfileID: Task<Void, Never>] = [:]
    private var extensionPinOrders: [ProfileID: [String]] = [:]

    init(store: BrowserSettingsStore) { self.store = store }

    func refresh() async {
        document = await store.snapshot()
        OrbitMotionPreferences.overrideReducedMotion = document.reducedMotion.override
        feedback.preferences = document.interaction
        onChange?()
    }

    func updateDownloads(_ edit: @Sendable (inout BrowserDownloadPreferences) -> Void) async throws {
        do { try await store.updateDownloads(edit) }
        catch { await refresh(); throw error }
        await refresh()
    }

    func updateInteraction(_ edit: @Sendable (inout BrowserInteractionPreferences) -> Void) async throws {
        do { try await store.updateInteraction(edit) }
        catch { await refresh(); throw error }
        await refresh()
    }

    func setOpensExternalLinksInQuickWindow(_ value: Bool) async throws {
        do { try await store.setOpensExternalLinksInQuickWindow(value) }
        catch { await refresh(); throw error }
        await refresh()
    }

    func setQuickWindowArchiveThreshold(_ threshold: BrowserAutoArchiveThreshold) async throws {
        do { try await store.setQuickWindowArchiveThreshold(threshold) }
        catch { await refresh(); throw error }
        await refresh()
    }

    func updateAI(_ edit: @Sendable (inout BrowserAIPreferences) -> Void) async throws {
        do { try await store.updateAI(edit) }
        catch { await refresh(); throw error }
        await refresh()
    }

    static var enablesBoostsTitle: String { uiText("Enable Boosts on websites you visit") }

    func setAllowJavaScriptFromAppleEvents(_ enabled: Bool) async throws {
        do { try await store.setAllowJavaScriptFromAppleEvents(enabled) }
        catch { await refresh(); throw error }
        await refresh()
    }

    func markBoostsIntroductionSeen() async throws {
        try await store.markBoostsIntroductionSeen()
        await refresh()
    }

    func setEnablesBoostsOnWebsites(_ enabled: Bool) async throws {
        do { try await store.setEnablesBoostsOnWebsites(enabled) }
        catch { await refresh(); throw error }
        await refresh()
    }

    func updateProfile(_ id: ProfileID, _ edit: @Sendable (inout BrowserProfileSettings) -> Void) async throws {
        do { try await store.updateProfile(id, edit) }
        catch { await refresh(); throw error }
        await refresh()
    }

    /// Serialize pin changes across windows without replacing unrelated profile preferences.
    func saveExtensionPinOrder(_ order: [String], profileID: ProfileID, onError: @escaping (Error) -> Void) {
        extensionPinOrders[profileID] = order
        let previous = extensionPinSaves[profileID]
        extensionPinSaves[profileID] = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { try await updateProfile(profileID) { $0.extensionPinOrder = order } }
            catch { onError(error) }
        }
    }

    func extensionPinOrder(for profileID: ProfileID) -> [String] {
        extensionPinOrders[profileID] ?? document.profile(profileID).extensionPinOrder
    }

    func flushExtensionPinOrders() async {
        for task in extensionPinSaves.values { await task.value }
    }

    func updateSpace(_ id: SpaceID, _ edit: @Sendable (inout BrowserSpaceSettings) -> Void) async throws {
        do { try await store.updateSpace(id, edit) }
        catch { await refresh(); throw error }
        await refresh()
    }

    func updateSpace(_ id: SpaceID, authority: BrowserSpaceSettingsAuthority,
                     _ edit: @Sendable (inout BrowserSpaceSettings) -> Void) async throws {
        do { try await store.updateSpace(id, authority: authority, edit) }
        catch { await refresh(); throw error }
        await refresh()
    }
}

@MainActor
final class BrowserWindowSettings {
    let runtime: BrowserSettingsRuntime
    init(runtime: BrowserSettingsRuntime) { self.runtime = runtime }

    /// Runs after the sidebar has rebuilt its Space buttons. Any palette query made while
    /// rendering the new profile is replaced with the correct profile's search engine.
    func renderSession<Engine: BrowserEngine>(in owner: BrowserWindowController<Engine>) {
        let previousSearchEngine = owner.addressResolver.searchEngine
        apply(to: owner)
        renderIcons(in: owner)
        if previousSearchEngine != owner.addressResolver.searchEngine, owner.palette.isPresented {
            owner.palette.query(owner.palette.view.input.stringValue, preserveSelection: true, userInitiated: false)
        }
    }

    func apply<Engine: BrowserEngine>(to owner: BrowserWindowController<Engine>) {
        owner.palette.siteSearches = runtime.document.siteSearches
        owner.sidebar.onReorderSnap = { [weak runtime] in runtime?.feedback.reorderSnapped() }
        guard let profileID = owner.session.activeProfileID else { return }
        let settings = runtime.document.profile(profileID)
        owner.addressResolver.searchEngine = settings.searchEngine
        owner.palette.showsSearchSuggestions = settings.showSearchSuggestions
        owner.peek.settings.opensPinnedLinksInPeek = settings.opensPinnedLinksInPeek
        owner.peek.settings.shiftClickOpensPeek = settings.shiftClickOpensPeek
    }

    func theme(for spaceID: SpaceID?) -> OrbitTokens.SpaceTheme? {
        guard let spaceID else { return nil }
        switch runtime.document.space(spaceID).palette {
        case .automatic: return nil
        case .amberCoral: return .amberCoral
        case .lavender: return .lavender
        case .rosePlum: return .rosePlum
        case .limeCitrus: return .limeCitrus
        }
    }

    func renderIcons<Engine: BrowserEngine>(in owner: BrowserWindowController<Engine>) {
        if let id = owner.sidebar.page.spaceID {
            owner.sidebar.page.iconSelection = runtime.document.space(id).iconSelection
        }
        for button in owner.sidebar.footer.spaceButtons {
            let icon = runtime.document.space(button.space.id).iconSelection
            button.iconSelection = icon
        }
    }
}
