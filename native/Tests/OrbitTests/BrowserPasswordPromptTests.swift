import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

@MainActor
private final class PromptSource: BrowserPasswordPromptSource {
    var pendingPasswordPrompt: BrowserPasswordPrompt?
    var observer: (@MainActor (BrowserPasswordPromptEvent, BrowserPasswordPrompt) -> Void)?
    var decisions: [BrowserPasswordDecision] = []
    func observePasswordPrompt(_ observer: (@MainActor (BrowserPasswordPromptEvent, BrowserPasswordPrompt) -> Void)?) { self.observer = observer }
    func send(_ event: BrowserPasswordPromptEvent, _ prompt: BrowserPasswordPrompt) {
        pendingPasswordPrompt = prompt
        observer?(event, prompt)
    }
    func decidePasswordPrompt(_ decision: BrowserPasswordDecision, generation: UInt64) -> Bool {
        guard let value = pendingPasswordPrompt, value.generation == generation else { return false }
        decisions.append(decision)
        pendingPasswordPrompt = nil
        observer?(.hide, value)
        return true
    }
    func reopenPasswordPrompt(generation: UInt64) -> Bool { false }
}

@Suite("Native password prompt lifecycle")
@MainActor
struct BrowserPasswordPromptTests {
    private func value(_ profile: ProfileID, generation: UInt64 = 1, state: BrowserPasswordPrompt.State = .save) -> BrowserPasswordPrompt {
        .init(profileID: profile, generation: generation, state: state, origin: "http://127.0.0.1:9876",
              username: "fixture", passwordMasked: true, canReopen: true)
    }

    @Test("All decisions reach only the current engine model and are one shot")
    func decisions() {
        for decision in [BrowserPasswordDecision.notNow, .never, .save] {
            let session = BrowserPasswordPromptSession(), source = PromptSource(), profile = ProfileID()
            var action: ((BrowserPasswordDecision) -> Void)?
            session.isCurrent = { true }
            session.onShow = { _, choose in action = choose }
            session.select(source, profileID: profile)
            source.send(.show, value(profile))
            action?(decision); action?(decision)
            #expect(source.decisions == [decision])
            #expect(session.prompt == nil)
        }
    }

    @Test("Selection, window and profile changes revoke retained action closures without a decision")
    func contextInvalidation() {
        let session = BrowserPasswordPromptSession(), source = PromptSource(), profile = ProfileID()
        var current = true
        var action: ((BrowserPasswordDecision) -> Void)?
        session.isCurrent = { current }
        session.onShow = { _, choose in action = choose }
        session.select(source, profileID: profile)
        source.send(.show, value(profile))
        current = false
        action?(.save)
        #expect(source.decisions.isEmpty)
        current = true
        let lateObserver = source.observer
        session.select(nil, profileID: nil)
        lateObserver?(.show, value(profile))
        action?(.save)
        #expect(session.prompt == nil)
        #expect(source.observer == nil)
        session.select(source, profileID: ProfileID())
        source.send(.show, value(profile))
        action?(.save)
        #expect(source.decisions.isEmpty)
        #expect(session.prompt == nil)
    }

    @Test("Replacement, hide and silent engine invalidation reject stale actions")
    func generationInvalidation() {
        let session = BrowserPasswordPromptSession(), source = PromptSource(), profile = ProfileID()
        var action: ((BrowserPasswordDecision) -> Void)?
        session.isCurrent = { true }
        session.onShow = { _, choose in action = choose }
        session.select(source, profileID: profile)
        source.send(.show, value(profile))
        let old = action
        source.send(.show, value(profile, generation: 2))
        old?(.save)
        #expect(source.decisions.isEmpty)
        source.pendingPasswordPrompt = value(profile, generation: 3)
        action?(.save)
        #expect(source.decisions.isEmpty)
        source.send(.hide, value(profile, generation: 4))
        action?(.save)
        #expect(session.prompt == nil)
        #expect(source.decisions.isEmpty)
    }

    @Test("Update allows save or decline and refuses site blocking; generated confirmations remain engine-owned")
    func variants() {
        let session = BrowserPasswordPromptSession(), source = PromptSource(), profile = ProfileID()
        var action: ((BrowserPasswordDecision) -> Void)?
        var presentations = 0
        session.isCurrent = { true }
        session.onShow = { _, choose in action = choose; presentations += 1 }
        session.select(source, profileID: profile)
        source.send(.show, value(profile, state: .update))
        action?(.never)
        #expect(source.decisions.isEmpty)
        action?(.save)
        #expect(source.decisions == [.save])
        source.send(.show, value(profile, generation: 2, state: .generated))
        #expect(presentations == 1)
    }
}
