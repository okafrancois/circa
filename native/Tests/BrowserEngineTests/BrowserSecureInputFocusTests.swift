import BrowserEngine
import Testing

@Suite("Secure input focus reconciliation")
struct BrowserSecureInputFocusTests {
    private var focused: BrowserSecureInputFocus {
        .init(applicationActive: true, windowKey: true, windowVisible: true, viewVisible: true,
              responderInSurface: true, retired: false)
    }

    @Test("Every loss of keyboard eligibility releases the engine scope")
    func allExitPaths() {
        let changes: [(inout BrowserSecureInputFocus) -> Void] = [
            { $0.applicationActive = false }, { $0.windowKey = false }, { $0.windowVisible = false },
            { $0.viewVisible = false }, { $0.responderInSurface = false }, { $0.retired = true }
        ]
        for change in changes {
            var focus = focused
            var reconciliation = BrowserSecureInputFocusReconciliation()
            #expect(focus.permitsSecureInput)
            #expect(reconciliation.update(eligible: true, secureInputEnabled: true) == nil)
            change(&focus)
            #expect(!focus.permitsSecureInput)
            #expect(reconciliation.update(eligible: focus.permitsSecureInput, secureInputEnabled: true) == false)
            #expect(reconciliation.update(eligible: false, secureInputEnabled: false) == nil)
            #expect(reconciliation.update(eligible: true, secureInputEnabled: false) == true)
            #expect(reconciliation.update(eligible: true, secureInputEnabled: true) == nil)
        }
    }

    @Test("A late background enable is reconciled again without a raw Carbon decrement")
    func lateEnable() {
        var reconciliation = BrowserSecureInputFocusReconciliation()
        #expect(reconciliation.update(eligible: false, secureInputEnabled: false) == false)
        #expect(reconciliation.update(eligible: false, secureInputEnabled: true) == false)
        #expect(reconciliation.update(eligible: false, secureInputEnabled: false) == nil)
    }

    @Test("Returning to a regular field restores engine focus without enabling secure input")
    func balance() {
        var reconciliation = BrowserSecureInputFocusReconciliation()
        var passwordScope = true
        var enables = 1
        var disables = 0
        func setActive(_ active: Bool, password: Bool) {
            let requested = active && password
            if requested != passwordScope {
                if requested { enables += 1 } else { disables += 1 }
                passwordScope = requested
            }
        }
        for _ in 0..<3 {
            if let active = reconciliation.update(eligible: false, secureInputEnabled: passwordScope) { setActive(active, password: true) }
            // A delayed renderer blur must remain balanced after the safety net's release.
            setActive(false, password: true)
            if let active = reconciliation.update(eligible: true, secureInputEnabled: passwordScope) { setActive(active, password: false) }
            #expect(!passwordScope)
        }
        #expect(enables == disables)
    }
}
