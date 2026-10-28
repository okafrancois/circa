import Foundation
import BrowserCore

/// Metadata only. The password remains in the engine's pending model.
public struct BrowserPasswordPrompt: Equatable, Sendable {
    public enum State: Int32, Sendable { case none, save, update, generated }
    public let profileID: ProfileID
    public let generation: UInt64
    public let state: State
    public let origin: String
    public let username: String
    public let passwordMasked: Bool
    public let canReopen: Bool

    public init(profileID: ProfileID, generation: UInt64, state: State, origin: String,
                username: String, passwordMasked: Bool, canReopen: Bool) {
        self.profileID = profileID
        self.generation = generation
        self.state = state
        self.origin = origin
        self.username = username
        self.passwordMasked = passwordMasked
        self.canReopen = canReopen
    }
}

public enum BrowserPasswordPromptEvent: Int32, Sendable { case show = 1, hide, stateChanged }
public enum BrowserPasswordDecision: Int32, Sendable { case save = 1, never, notNow }

@MainActor
public protocol BrowserPasswordPromptSource: AnyObject {
    /// Nil disables presentation without declining or saving. Never log these fields.
    func observePasswordPrompt(_ observer: (@MainActor (BrowserPasswordPromptEvent, BrowserPasswordPrompt) -> Void)?)
    var pendingPasswordPrompt: BrowserPasswordPrompt? { get }
    @discardableResult func decidePasswordPrompt(_ decision: BrowserPasswordDecision, generation: UInt64) -> Bool
    @discardableResult func reopenPasswordPrompt(generation: UInt64) -> Bool
}
