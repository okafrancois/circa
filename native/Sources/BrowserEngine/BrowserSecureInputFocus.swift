/// Focus eligibility is independent of the renderer's remembered DOM focus. A background
/// document can still contain the active password element without owning keyboard input.
public struct BrowserSecureInputFocus: Equatable, Sendable {
    public var applicationActive: Bool
    public var windowKey: Bool
    public var windowVisible: Bool
    public var viewVisible: Bool
    public var responderInSurface: Bool
    public var retired: Bool

    public init(applicationActive: Bool, windowKey: Bool, windowVisible: Bool, viewVisible: Bool,
                responderInSurface: Bool, retired: Bool) {
        self.applicationActive = applicationActive
        self.windowKey = windowKey
        self.windowVisible = windowVisible
        self.viewVisible = viewVisible
        self.responderInSurface = responderInSurface
        self.retired = retired
    }

    public var permitsSecureInput: Bool {
        applicationActive && windowKey && windowVisible && viewVisible && responderInSurface && !retired
    }
}

/// Reconcile through the engine's focus API, never by decrementing the process-wide Carbon
/// count. A later renderer blur must still be free to balance its own password scope.
public struct BrowserSecureInputFocusReconciliation: Sendable {
    private var previouslyEligible: Bool?
    public init() {}

    public mutating func update(eligible: Bool, secureInputEnabled: Bool) -> Bool? {
        defer { previouslyEligible = eligible }
        if !eligible {
            return previouslyEligible != false || secureInputEnabled ? false : nil
        }
        return previouslyEligible == false ? true : nil
    }
}
