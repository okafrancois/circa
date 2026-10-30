import AppKit
import BrowserShell

/// Scope is part of a binding: a Little Circa command must never fall through to a main tab.
enum BrowserCommandScope: String, Sendable { case browser, responder, palette, switcher, quickWindow, peek }
enum BrowserCommandRequirement: Sendable { case application, window, surface, url, back, forward, loading, reopen, responder }
enum BrowserCommandOrigin: Sendable, Equatable { case menu, keyboard, palette, contextMenu }

struct BrowserCommandDefinition: Sendable {
    let id: BrowserCommandID
    let title: String
    let menu: String
    var shortcuts: [BrowserShortcut]
    let scope: BrowserCommandScope
    let requirement: BrowserCommandRequirement
    let owner: String
    var sources: [String]

    var localizedTitle: String {
        uiText(title)
    }
}

/// No addresses or browsing content are retained in command targets.
struct BrowserCommandContext: Equatable {
    let revision: UInt64
    let surface: ObjectIdentifier?
    let documentGeneration: UInt64
    let inputToken: UUID
}

struct BrowserCommandState {
    var isAvailable = true
    var isModal = false
    var hasWindow = false
    var hasSurface = false
    var hasURL = false
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var canReopen = false
    var hasPendingCommands = false
    var scope: BrowserCommandScope = .browser
    var context: BrowserCommandContext?
}

enum BrowserCommandCapturePolicy { case explicitInput, document }

struct BrowserCommandTarget {
    let windowID: UUID
    let context: BrowserCommandContext
    var policy: BrowserCommandCapturePolicy = .explicitInput

    func matches(_ current: BrowserCommandContext?) -> Bool {
        guard let current else { return false }
        return context.revision == current.revision && context.surface == current.surface
            && context.documentGeneration == current.documentGeneration
            && (policy == .document || context.inputToken == current.inputToken)
    }
}

enum BrowserCommandRegistryError: Error { case duplicateDefinition(BrowserCommandID), duplicateHandler(BrowserCommandID), unknownCommand }

/// Handlers submit synchronously to the existing router/session queues. The registry adds no
/// Task or queue: doing so would reorder input relative to sidebar and engine commands.
@MainActor
final class BrowserCommandRegistry<Window: AnyObject> {
    typealias Handler = (Window, BrowserCommandOrigin) -> Void
    let eventInputs = BrowserShortcutEventCache()
    let keyTrace = BrowserKeyRoutingTrace()
    private(set) var definitions: [BrowserCommandDefinition]
    let defaultDefinitions: [BrowserCommandDefinition]
    var shortcutPreferences = BrowserShortcutPreferences()
    var onShortcutsChanged: (() -> Void)?
    let router: BrowserWindowRouter<Window>
    private let state: (Window?) -> BrowserCommandState
    private let currentWindowID: () -> UUID?
    private let permitsMissingWindow: () -> Bool
    private let deliver: (Window, @escaping () -> Void) -> Void
    private var windowHandlers: [BrowserCommandID: Handler] = [:]
    private struct ScopedApplicationHandler {
        let validate: () -> Bool
        let action: () -> Void
    }
    private var scopedApplicationHandlers: [BrowserCommandID: [BrowserCommandScope: ScopedApplicationHandler]] = [:]
    private var applicationHandlers: [BrowserCommandID: () -> Void] = [:]
    private var missingWindowHandlers: [BrowserCommandID: (BrowserCommandOrigin) -> Void] = [:]
    private var modalPermissions: Set<BrowserCommandID> = []
    private var prerequisites: [BrowserCommandID: (Window?, BrowserCommandState) -> Bool] = [:]
    private var scopeProviders: [String: (priority: Int, provider: (Window?) -> BrowserCommandScope?)] = [:]
    private var keyEquivalentMatcher: BrowserKeyEquivalentMatcher
    private var inputHandlers: [(name: String, handler: (Window?, NSEvent) -> Bool)] = []
    private var validators: [BrowserCommandID: (Window) -> Bool] = [:]
    /// Explicitly serialized responder handlers may opt in for their exact resolved target.
    private var pendingResponderPermissions: [BrowserCommandID: (Window) -> Bool] = [:]

    init(definitions: [BrowserCommandDefinition] = OrbitCommandCatalog.definitions,
         router: BrowserWindowRouter<Window>, state: @escaping (Window?) -> BrowserCommandState,
         currentWindowID: (() -> UUID?)? = nil,
         permitsMissingWindow: @escaping () -> Bool = { true },
         deliver: @escaping (Window, @escaping () -> Void) -> Void = { _, action in action() }) throws {
        var seen: Set<BrowserCommandID> = []
        for definition in definitions {
            guard seen.insert(definition.id).inserted else { throw BrowserCommandRegistryError.duplicateDefinition(definition.id) }
        }
        self.defaultDefinitions = definitions
        self.definitions = definitions
        self.keyEquivalentMatcher = BrowserKeyEquivalentMatcher(bindings: definitions.flatMap(\.shortcuts))
        self.router = router
        self.currentWindowID = currentWindowID ?? { router.selectedWindowID }
        self.permitsMissingWindow = permitsMissingWindow
        self.state = state
        self.deliver = deliver
    }

    func useShortcutPreferences(_ preferences: BrowserShortcutPreferences) {
        shortcutPreferences = preferences
        preferences.onChange = { [weak self] in self?.refreshShortcuts() }
        refreshShortcuts()
    }

    private func refreshShortcuts() {
        definitions = defaultDefinitions.map { definition in
            var updated = definition
            updated.shortcuts = shortcutPreferences.bindings(for: definition)
            return updated
        }
        customizedBindings = Set(shortcutPreferences.document.overrides.values.flatMap { $0.map(\.shortcut) })
        eventInputs.clear()
        keyEquivalentMatcher = BrowserKeyEquivalentMatcher(bindings: definitions.flatMap(\.shortcuts))
        onShortcutsChanged?()
    }

    func prefersBrowser(_ id: BrowserCommandID) -> Bool {
        if let preference = shortcutPreferences.priority(for: id) { return preference == .browser }
        return definition(id).map { BrowserShortcutPriority.isReserved(id, commandScope: $0.scope) } ?? false
    }

    private var customizedBindings: Set<BrowserShortcut> = []
    private var lastWebsiteShortcut: (id: BrowserCommandID, window: UUID?, time: TimeInterval)?
    func isSecondWebsiteShortcut(_ id: BrowserCommandID, event: BrowserShortcutEvent) -> Bool {
        guard shortcutPreferences.priority(for: id) == .both, let native = event.nativeEvent else { return false }
        let previous = lastWebsiteShortcut
        lastWebsiteShortcut = (id, currentWindowID(), native.timestamp)
        guard !native.isARepeat, let previous, previous.id == id, previous.window == currentWindowID(),
              native.timestamp > previous.time, native.timestamp - previous.time < 0.5 else { return false }
        lastWebsiteShortcut = nil
        return true
    }

    var hasBrowserCommandTarget: Bool { currentWindowID() != nil }

    func definition(_ id: BrowserCommandID) -> BrowserCommandDefinition? { definitions.first { $0.id == id } }
    func isImplemented(_ id: BrowserCommandID) -> Bool { windowHandlers[id] != nil || applicationHandlers[id] != nil || scopedApplicationHandlers[id] != nil }

    func register(_ id: BrowserCommandID, replace: Bool = false,
                  allowsDuringModal: Bool = false, allowsPendingResponder: ((Window) -> Bool)? = nil,
                  validate: ((Window) -> Bool)? = nil, handler: @escaping Handler) throws {
        try checkRegistration(id, replace: replace)
        applicationHandlers[id] = nil
        windowHandlers[id] = handler
        validators[id] = validate
        pendingResponderPermissions[id] = allowsPendingResponder
        setModalPermission(id, allowed: allowsDuringModal)
    }

    func registerApplication(_ id: BrowserCommandID, replace: Bool = false, allowsDuringModal: Bool = false, handler: @escaping () -> Void) throws {
        try checkRegistration(id, replace: replace)
        windowHandlers[id] = nil
        validators[id] = nil
        pendingResponderPermissions[id] = nil
        applicationHandlers[id] = handler
        setModalPermission(id, allowed: allowsDuringModal)
    }

    /// An auxiliary document host can share the browser command ID and menu while supplying
    /// its own target. It never borrows or replaces the background browser's handler.
    func registerScopedApplication(_ id: BrowserCommandID, scope: BrowserCommandScope,
        validate: @escaping () -> Bool, handler: @escaping () -> Void) throws {
        guard definition(id) != nil else { throw BrowserCommandRegistryError.unknownCommand }
        guard scopedApplicationHandlers[id]?[scope] == nil else { throw BrowserCommandRegistryError.duplicateHandler(id) }
        scopedApplicationHandlers[id, default: [:]][scope] = .init(validate: validate, action: handler)
    }

    private func setModalPermission(_ id: BrowserCommandID, allowed: Bool) {
        if allowed { modalPermissions.insert(id) } else { modalPermissions.remove(id) }
    }

    /// Features install prerequisites without changing the catalog's core requirement switch.
    func registerPrerequisite(_ id: BrowserCommandID,
                              validate: @escaping (Window?, BrowserCommandState) -> Bool) {
        prerequisites[id] = validate
    }

    /// Higher priorities represent overlays above a window scope. IDs and priorities must be
    /// unique: deterministic selection must never depend on dictionary or registration order.
    func registerScopeProvider(_ name: String, priority: Int,
                               provider: @escaping (Window?) -> BrowserCommandScope?) {
        precondition(scopeProviders[name] == nil && !scopeProviders.values.contains { $0.priority == priority })
        scopeProviders[name] = (priority, provider)
    }

    func unregisterScopeProvider(_ name: String) { scopeProviders[name] = nil }

    /// Feature-owned modal input shares the CMD monitor, including modifier release and clicks.
    func registerInputHandler(_ name: String, handler: @escaping (Window?, NSEvent) -> Bool) {
        precondition(!inputHandlers.contains { $0.name == name })
        inputHandlers.append((name, handler))
    }

    func handleInputEvent(_ event: NSEvent) -> Bool {
        let window = currentWindowID().flatMap { router.windows[$0] }
        return inputHandlers.contains { $0.handler(window, event) }
    }

    var activeScope: BrowserCommandScope {
        let window = currentWindowID().flatMap { router.windows[$0] }
        return scope(in: window)
    }

    private func scope(in window: Window?) -> BrowserCommandScope {
        for entry in scopeProviders.values.sorted(by: { $0.priority > $1.priority }) {
            if let scope = entry.provider(window) { return scope }
        }
        return state(window).scope
    }

    /// Creation policy is explicit and applies only when there is no selected/requested window.
    func registerWhenWindowMissing(_ id: BrowserCommandID, handler: @escaping () -> Void) throws {
        try registerWhenWindowMissing(id, withOrigin: { _ in handler() })
    }

    func registerWhenWindowMissing(_ id: BrowserCommandID,
                                   withOrigin handler: @escaping (BrowserCommandOrigin) -> Void) throws {
        guard windowHandlers[id] != nil else { throw BrowserCommandRegistryError.unknownCommand }
        missingWindowHandlers[id] = handler
    }

    /// Resume a previously accepted missing-window command after the router has restored
    /// its window. Reuse the current registered handler, including later feature overrides.
    @discardableResult
    func performRestoredWindowCommand(_ id: BrowserCommandID, in window: Window,
                                      origin: BrowserCommandOrigin) -> Bool {
        let snapshot = state(window)
        guard missingWindowHandlers[id] != nil, let handler = windowHandlers[id],
              snapshot.isAvailable, !snapshot.isModal || modalPermissions.contains(id),
              validators[id]?(window) != false,
              prerequisites[id]?(window, snapshot) != false else { return false }
        deliver(window) { handler(window, origin) }
        return true
    }

    private func checkRegistration(_ id: BrowserCommandID, replace: Bool) throws {
        guard definition(id) != nil else { throw BrowserCommandRegistryError.unknownCommand }
        guard replace || !isImplemented(id) else { throw BrowserCommandRegistryError.duplicateHandler(id) }
    }

    /// Context menus/palettes capture before being displayed. A busy session cannot supply a
    /// stable displayed target; callers should retry after publication, never substitute focus.
    func captureTarget(windowID: UUID? = nil, policy: BrowserCommandCapturePolicy = .explicitInput) -> BrowserCommandTarget? {
        guard let id = windowID ?? currentWindowID(), let window = router.windows[id] else { return nil }
        let snapshot = state(window)
        guard snapshot.isAvailable, !snapshot.hasPendingCommands, let context = snapshot.context else { return nil }
        return BrowserCommandTarget(windowID: id, context: context, policy: policy)
    }

    /// Palette typing is independent of the address field's explicit-input generation. A
    /// navigation, selection/revision change, document replacement or retirement still revokes it.
    func capturePaletteTarget(windowID: UUID? = nil) -> BrowserCommandTarget? {
        captureTarget(windowID: windowID, policy: .document)
    }

    func isEnabled(_ id: BrowserCommandID, target: BrowserCommandTarget? = nil) -> Bool {
        guard let definition = definition(id), isImplemented(id) else { return false }
        let windowID = target?.windowID ?? currentWindowID()
        let window = windowID.flatMap { router.windows[$0] }
        let snapshot = state(window)
        guard snapshot.isAvailable else { return false }
        if let target {
            guard window != nil, !snapshot.hasPendingCommands, target.matches(snapshot.context) else { return false }
        }
        if snapshot.isModal && !modalPermissions.contains(id) { return false }
        if target == nil, let handler = scopedApplicationHandlers[id]?[scope(in: window)] { return handler.validate() }
        if let prerequisite = prerequisites[id], !prerequisite(window, snapshot) { return false }
        if applicationHandlers[id] != nil {
            // Global application actions have no document target. In particular New Window
            // must not inherit from a different selected window than a captured context menu.
            return target == nil
        }
        guard windowID != nil else { return target == nil && permitsMissingWindow() && missingWindowHandlers[id] != nil }
        if definition.scope != .browser && definition.scope != .responder && definition.scope != scope(in: window) { return false }
        // Only implemented window handlers may be accepted across publication gaps. Their
        // session primitives revalidate at execution, in the order already accepted.
        let pending = window == nil || snapshot.hasPendingCommands || (windowID == router.selectedWindowID && router.hasPendingSelectedWindowCommands)
        if definition.requirement == .responder {
            guard let window else { return false }
            if pending, pendingResponderPermissions[id]?(window) != true { return false }
            return validators[id]?(window) == true
        }
        if pending { return target == nil }
        if let window, let validate = validators[id], !validate(window) { return false }
        switch definition.requirement {
        case .application: return true
        case .window: return snapshot.hasWindow
        case .surface: return snapshot.hasSurface
        case .url: return snapshot.hasSurface && snapshot.hasURL
        case .back: return snapshot.canGoBack
        case .forward: return snapshot.canGoForward
        case .loading: return snapshot.isLoading
        case .reopen: return snapshot.canReopen
        case .responder: return false
        }
    }

    /// True means accepted; a failed/retired target may subsequently cancel, never redirect.
    /// Object-menu owners use `onDropped` to retire the exact invocation when delivery revalidation
    /// refuses a still-live window (including a busy session whose context did not change).
    @discardableResult
    func dispatch(_ id: BrowserCommandID, origin: BrowserCommandOrigin,
                  target: BrowserCommandTarget? = nil, onDropped: (() -> Void)? = nil,
                  onDelivered: (() -> Void)? = nil) -> Bool {
        guard isEnabled(id, target: target) else {
            keyTrace.record("dispatch", nil, "command=\(id.rawValue) result=disabled")
            return false
        }
        keyTrace.record("dispatch", nil, "command=\(id.rawValue) result=accepted")
        if target == nil, let handler = scopedApplicationHandlers[id]?[activeScope] {
            handler.action(); onDelivered?(); return true
        }
        if let handler = applicationHandlers[id] { handler(); onDelivered?(); return true }
        if target == nil, currentWindowID() == nil, let handler = missingWindowHandlers[id] {
            handler(origin)
            onDelivered?()
            return true
        }
        guard let targetID = target?.windowID ?? currentWindowID(),
              let handler = windowHandlers[id] else { return false }
        router.perform(in: targetID) { [weak self] window in
            guard let self else { onDropped?(); return }
            if let target {
                let current = self.state(window)
                guard !current.hasPendingCommands, target.matches(current.context) else { onDropped?(); return }
            }
            self.deliver(window) { handler(window, origin); onDelivered?() }
        }
        return true
    }

    /// A scope-specific binding shadows the browser binding even when disabled. The one
    /// historical catalog collision is an explicit product decision, independent of menu order.
    func resolve(_ shortcut: BrowserShortcut, scope: BrowserCommandScope? = nil) -> BrowserCommandID? {
        resolve(scope: scope) { $0 == shortcut }
    }

    func resolve(_ event: NSEvent, scope: BrowserCommandScope? = nil) -> BrowserCommandID? {
        guard let input = eventInputs.normalized(event) else { return nil }
        return resolve(input, scope: scope)
    }

    func resolve(_ input: BrowserShortcutEvent, scope: BrowserCommandScope? = nil) -> BrowserCommandID? {
        resolve(scope: scope) { matches($0, input: input) }
    }

    /// Resolve the declared command before checking availability, for browser reservation.
    func resolveBinding(_ input: BrowserShortcutEvent, scope: BrowserCommandScope? = nil) -> BrowserCommandID? {
        resolve(scope: scope, includingDisabled: true) { matches($0, input: input) }
    }

    private func matches(_ binding: BrowserShortcut, input: BrowserShortcutEvent) -> Bool {
        if customizedBindings.contains(binding), let event = input.nativeEvent {
            return BrowserShortcut.recordedInput(event) == binding
        }
        return keyEquivalentMatcher.matches(binding, input: input)
    }

    func matchingDefinitions(_ input: BrowserShortcutEvent) -> [BrowserCommandDefinition] {
        definitions.filter { definition in
            definition.shortcuts.contains { matches($0, input: input) }
        }
    }

    func hasUnshiftedFunctionBinding(_ input: BrowserShortcutEvent) -> Bool {
        guard input.shortcut.modifiers.contains(.shift),
              input.shortcut.key.unicodeScalars.first.map({ (0xF700...0xF8FF).contains($0.value) }) == true else { return false }
        return definitions.contains { definition in
            definition.shortcuts.contains { binding in
                !binding.modifiers.contains(.shift)
                    && binding.key.unicodeScalars.first.map({ (0xF700...0xF8FF).contains($0.value) }) == true
                    && keyEquivalentMatcher.matches(binding, input: input, strictShift: false)
            }
        }
    }

    private func resolve(scope: BrowserCommandScope?, includingDisabled: Bool = false, matching: (BrowserShortcut) -> Bool) -> BrowserCommandID? {
        let scope = scope ?? activeScope
        let scoped = definitions.filter { $0.scope == scope && $0.shortcuts.contains(where: matching) }
        let candidates = scoped.isEmpty && scope != .browser
            ? definitions.filter { ($0.scope == .browser || $0.scope == .responder) && $0.shortcuts.contains(where: matching) }
            : scoped + definitions.filter { scope != .responder && $0.scope == .responder && $0.shortcuts.contains(where: matching) }
        if candidates.contains(where: { $0.id == .newIncognitoWindow }),
           candidates.contains(where: { $0.id == .newFolder }) {
            return includingDisabled || isEnabled(.newIncognitoWindow) ? .newIncognitoWindow : nil
        }
        let matches = includingDisabled ? candidates : candidates.filter { isEnabled($0.id) }
        return matches.count == 1 ? matches[0].id : nil
    }

    var shortcutConflicts: [[BrowserCommandID]] {
        var bindings: [String: [BrowserCommandID]] = [:]
        for definition in definitions {
            for shortcut in Set(definition.shortcuts) {
                bindings["\(definition.scope.rawValue):\(shortcut.modifiers.rawValue):\(shortcut.key)", default: []].append(definition.id)
            }
        }
        return bindings.values.filter { $0.count > 1 }.map { $0.sorted { $0.rawValue < $1.rawValue } }
            .sorted { $0[0].rawValue < $1[0].rawValue }
    }
}
