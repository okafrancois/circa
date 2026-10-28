import BrowserCore
import BrowserEngine
import Testing

@MainActor
private final class PasswordPromptFake: BrowserPasswordPromptSource {
    var pendingPasswordPrompt: BrowserPasswordPrompt?
    var observer: (@MainActor (BrowserPasswordPromptEvent, BrowserPasswordPrompt) -> Void)?
    func observePasswordPrompt(_ observer: (@MainActor (BrowserPasswordPromptEvent, BrowserPasswordPrompt) -> Void)?) {
        self.observer = observer
    }
    func submit(_ prompt: BrowserPasswordPrompt) {
        pendingPasswordPrompt = prompt
        observer?(.stateChanged, prompt)
        observer?(.show, prompt)
    }
    func decidePasswordPrompt(_ decision: BrowserPasswordDecision, generation: UInt64) -> Bool {
        guard let pending = pendingPasswordPrompt, pending.generation == generation,
              pending.canReopen, pending.state == .save || pending.state == .update,
              decision != .never || pending.state == .save else { return false }
        pendingPasswordPrompt = nil
        observer?(.hide, pending)
        return true
    }
    func reopenPasswordPrompt(generation: UInt64) -> Bool {
        guard let pending = pendingPasswordPrompt, pending.generation == generation, pending.canReopen else { return false }
        observer?(.show, pending)
        return true
    }
}

@Suite("Password prompt contract")
@MainActor
struct PasswordPromptContractTests {
    private func prompt(_ generation: UInt64, state: BrowserPasswordPrompt.State = .save) -> BrowserPasswordPrompt {
        .init(profileID: ProfileID(), generation: generation, state: state,
              origin: "https://example.test", username: "fixture-user", passwordMasked: true, canReopen: true)
    }

    @Test("Disabled observation preserves a pending model for explicit reopening")
    func disabledAdapter() {
        let fake = PasswordPromptFake()
        let pending = prompt(1)
        fake.submit(pending)
        #expect(fake.pendingPasswordPrompt == pending)
        var events: [BrowserPasswordPromptEvent] = []
        fake.observePasswordPrompt { event, value in
            events.append(event)
            #expect(value.passwordMasked)
            #expect(value.profileID == pending.profileID)
        }
        #expect(fake.reopenPasswordPrompt(generation: 1))
        #expect(events == [.show])
        fake.observePasswordPrompt(nil)
        #expect(fake.pendingPasswordPrompt == pending)
    }

    @Test("A decision is one shot and cannot target an older controller model")
    func decisions() {
        let fake = PasswordPromptFake()
        fake.submit(prompt(1))
        fake.submit(prompt(2, state: .update))
        #expect(!fake.decidePasswordPrompt(.save, generation: 1))
        #expect(!fake.decidePasswordPrompt(.never, generation: 2))
        #expect(fake.decidePasswordPrompt(.notNow, generation: 2))
        #expect(!fake.decidePasswordPrompt(.save, generation: 2))
    }
}
