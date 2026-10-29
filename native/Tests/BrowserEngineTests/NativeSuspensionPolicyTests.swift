import BrowserEngine
import Testing

@Suite("Native suspension eligibility")
struct NativeSuspensionPolicyTests {
    @Test("Unknown state refuses and clean state ignores native age and tab-policy reasons")
    func admission() {
        #expect(BrowserPageSuspensionPolicy.refusal(nil) != nil)
        var state = BrowserPageLifecycle()
        #expect(BrowserPageSuspensionPolicy.refusal(state) != nil)
        state.documentID = 1
        for bit in [4, 6, 7, 22, 23, 24] {
            state.cannotDiscardMask = 1 << bit
            #expect(BrowserPageSuspensionPolicy.refusal(state) == nil)
        }
        for bit in [0, 1, 3, 5, 8, 10, 11, 15, 16, 17, 18, 19, 25, 26, 27] {
            state.cannotDiscardMask = 1 << bit
            #expect(BrowserPageSuspensionPolicy.refusal(state) != nil)
        }
    }
    @Test("Every native activity veto is independent, including silent media and subframe edits")
    func protections() {
        for flag in [\BrowserPageLifecycle.playingMedia, \.playingVideo, \.audioContextRunning,
                     \.audible, \.pictureInPicture, \.hadFormInteraction, \.hadUserEdits,
                     \.webLock, \.indexedDBLock, \.webRTC] {
            var state = BrowserPageLifecycle(); state.documentID = 1
            state[keyPath: flag] = true
            #expect(BrowserPageSuspensionPolicy.refusal(state) != nil)
            state[keyPath: flag] = false
            #expect(BrowserPageSuspensionPolicy.refusal(state) == nil)
        }
        for bit in 0..<6 {
            var state = BrowserPageLifecycle(); state.documentID = 1; state.capturing = 1 << bit
            #expect(BrowserPageSuspensionPolicy.refusal(state) != nil)
        }
        var state = BrowserPageLifecycle(); state.documentID = 1; state.state = .discarded
        #expect(BrowserPageSuspensionPolicy.refusal(state) != nil)
    }
}
