import BrowserCore
import Foundation

/// Response from the engine's authenticated same-origin fetch. Contains no request headers or
/// cookies. Callers must not log the body or put it in synced documents.
public struct BrowserProfileWebResponse: Sendable {
    public let status: Int
    public let url: URL
    public let body: String
    public let retryAfter: String?
    public init(status: Int, url: URL, body: String, retryAfter: String? = nil) {
        self.status = status; self.url = url; self.body = body; self.retryAfter = retryAfter
    }
}

/// Restricted GitHub web transport. No arbitrary origin, headers, body, scripts or cookie access.
/// The engine owns an isolated background document, created in exactly `profileID`'s store.
@MainActor
public protocol BrowserGitHubWebSession: AnyObject {
    func pullRequests(profileID: ProfileID, query: String, page: Int) async throws -> BrowserProfileWebResponse
}

/// Read-only inbox metadata using the selected profile's existing web session.
/// Cookies and authentication stay inside the engine; results must remain ephemeral.
@MainActor
public protocol BrowserGmailWebSession: AnyObject {
    func gmailInbox(profileID: ProfileID, account: BrowserGmailAccount) async throws -> BrowserGmailInbox
}
