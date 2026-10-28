import Foundation

/// Revocable UI intent checked inside the store actor immediately before synchronous selection.
/// A successful store read admits the synchronous action. Revocation before that read vetoes it;
/// revocation afterward cannot cancel or roll back selection, even before the final state write.
public final class BrowserSidebarSelectionAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    public init() {}
    public var isValid: Bool { lock.withLock { valid } }
    public func revoke() { lock.withLock { valid = false } }
}
