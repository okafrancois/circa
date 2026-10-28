import Foundation

import BrowserCore
import BrowserEngine

/// Owns a single presentation lease. Neither losing that lease nor detaching an observer
/// makes a credential decision; only a current, explicit action can reach the engine.
@MainActor
final class BrowserPasswordPromptSession {
    private weak var source: (any BrowserPasswordPromptSource)?
    private var profileID: ProfileID?
    private var lease = UUID()
    private(set) var prompt: BrowserPasswordPrompt?
    var isCurrent: () -> Bool = { false }
    var onShow: ((BrowserPasswordPrompt, @escaping (BrowserPasswordDecision) -> Void) -> Void)?
    var onHide: ((_ animated: Bool) -> Void)?

    func select(_ next: (any BrowserPasswordPromptSource)?, profileID: ProfileID?) {
        guard source !== next || self.profileID != profileID else { return }
        lease = UUID()
        prompt = nil
        onHide?(false)
        source?.observePasswordPrompt(nil)
        source = next
        self.profileID = profileID
        let lease = lease
        next?.observePasswordPrompt { [weak self, weak next] event, value in
            guard let self, let next, self.lease == lease, self.source === next else { return }
            switch event {
            case .show:
                guard isCurrent(), value.profileID == self.profileID, value.passwordMasked,
                      value.canReopen, value.state == .save || value.state == .update else { return }
                prompt = value
                onShow?(value, { [weak self] decision in self?.decide(decision, lease: lease, value: value) })
            case .hide:
                prompt = nil
                onHide?(true)
            case .stateChanged:
                if let prompt, prompt != value { self.prompt = nil; onHide?(false) }
            }
        }
    }

    private func decide(_ decision: BrowserPasswordDecision, lease: UUID, value: BrowserPasswordPrompt) {
        guard self.lease == lease, isCurrent(), prompt == value, let source,
              source.pendingPasswordPrompt == value,
              decision != .never || value.state == .save else { return }
        prompt = nil
        // Hide callbacks may run synchronously during this call. Keep observation installed
        // until the engine has finished accepting the decision.
        let accepted = source.decidePasswordPrompt(decision, generation: value.generation)
        onHide?(accepted)
    }
}
