import Foundation
import BrowserCore
import BrowserEngine

/// One approved top-level request and its bounded same-origin redirect chain. Popups, downloads
/// and unrelated requests never inherit the approval. The host revokes this object on Stop.
@MainActor final class BrowserErrandNavigationGrant {
    let surfaceID: ObjectIdentifier
    let destination: URL
    let form: Bool
    private let expires: ContinuousClock.Instant
    private(set) var started = false
    private var redirects = 0
    private var revoked = false
    init(surface: AnyObject, destination: URL, form: Bool = false, lifetime: Duration = .seconds(15)) {
        surfaceID = ObjectIdentifier(surface); self.destination = destination; self.form = form
        expires = ContinuousClock.now.advanced(by: lifetime)
    }
    func revoke() { revoked = true }
    func permits(_ action: BrowserNavigationAction, from surface: AnyObject) -> Bool {
        guard !revoked, ContinuousClock.now < expires, ObjectIdentifier(surface) == surfaceID,
              action.isMainFrame == true, action.disposition == .currentTab, !action.shouldPerformDownload,
              let url = action.url, BrowserAIErrandAction.allowedURL(url), sameOrigin(url, destination) else { return false }
        if action.kind == .redirect {
            guard started, redirects < 4 else { return false }
            redirects += 1; return true
        }
        guard !started else { return false }
        var expected = URLComponents(url: destination, resolvingAgainstBaseURL: false)
        var actual = URLComponents(url: url, resolvingAgainstBaseURL: false)
        expected?.fragment = nil; actual?.fragment = nil
        if form {
            guard action.kind == .formSubmission else { return false }
            expected?.query = nil; actual?.query = nil
        }
        guard expected == actual else { return false }
        started = true
        return true
    }
    private func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }
}
