import Foundation

/// Shell safety vetoes, separate from Chromium's age, visibility and pinning policy.
public enum BrowserPageSuspensionPolicy {
    public static func refusal(_ state: BrowserPageLifecycle?) -> String? {
        guard let state, state.documentID != 0 else { return "unknown-lifecycle" }
        guard state.state != .discarded else { return "already-discarded" }
        if state.playingMedia || state.playingVideo || state.audioContextRunning || state.audible {
            return "playing-media"
        }
        if state.hadUserEdits { return "trusted-edit" }
        if state.hadFormInteraction { return "form-interaction" }
        if state.pictureInPicture || state.capturing != 0 || state.webLock || state.indexedDBLock || state.webRTC {
            return "native-protection"
        }
        // CannotDiscardReason: structural failures, audible, PiP, invalid/non-web URL,
        // capture, background activity, form interaction and user edits. In particular,
        // recently visible/audible, active and pinned are not shell safety vetoes.
        let reasons: [UInt64] = [0, 1, 3, 5, 8, 10, 11, 15, 16, 17, 18, 19, 25, 26, 27]
        let veto = reasons.reduce(UInt64(0)) { $0 | (1 << $1) }
        return state.cannotDiscardMask & veto != 0 ? "native-protection" : nil
    }
}
