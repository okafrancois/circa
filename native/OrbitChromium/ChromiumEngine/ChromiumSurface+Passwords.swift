import BrowserCore
import BrowserEngine
import OrbitChromiumBridge

extension ChromiumSurface: BrowserPasswordPromptSource {
    public var passwordPrompts: (any BrowserPasswordPromptSource)? { self }

    public func observePasswordPrompt(_ observer: (@MainActor (BrowserPasswordPromptEvent, BrowserPasswordPrompt) -> Void)?) {
        passwordPromptObserver = observer
        guard !isDisposed else { return }
        if observer == nil {
            _ = ACRPasswordPromptObserve(token, profileToken, nil, nil)
        } else {
            _ = ACRPasswordPromptObserve(token, profileToken, { context, event, snapshot in
                MainActor.assumeIsolated {
                    guard let context, let snapshot,
                          let event = BrowserPasswordPromptEvent(rawValue: event) else { return }
                    let token = UInt64(UInt(bitPattern: context))
                    guard let surface = ChromiumRuntime.shared.surface(token), !surface.isDisposed else { return }
                    surface.passwordPromptObserver?(event, surface.passwordPrompt(snapshot.pointee))
                }
            }, UnsafeMutableRawPointer(bitPattern: UInt(token)))
        }
    }

    public var pendingPasswordPrompt: BrowserPasswordPrompt? {
        guard !isDisposed else { return nil }
        var snapshot = orbit_password_prompt_t()
        snapshot.struct_size = UInt32(MemoryLayout<orbit_password_prompt_t>.size)
        guard ACRPasswordPromptSnapshot(token, profileToken, &snapshot) == 1 else { return nil }
        return passwordPrompt(snapshot)
    }

    public func decidePasswordPrompt(_ decision: BrowserPasswordDecision, generation: UInt64) -> Bool {
        !isDisposed && ACRPasswordPromptDecide(token, profileToken, generation, decision.rawValue) == 1
    }

    public func reopenPasswordPrompt(generation: UInt64) -> Bool {
        !isDisposed && ACRPasswordPromptReopen(token, profileToken, generation) == 1
    }

    private func passwordPrompt(_ value: orbit_password_prompt_t) -> BrowserPasswordPrompt {
        BrowserPasswordPrompt(profileID: profileID, generation: value.generation,
                              state: .init(rawValue: value.state) ?? .none,
                              origin: value.origin.map { String(cString: $0) } ?? "",
                              username: value.username.map { String(cString: $0) } ?? "",
                              passwordMasked: value.password_masked == 1, canReopen: value.can_reopen == 1)
    }
}
