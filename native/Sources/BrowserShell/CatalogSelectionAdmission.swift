import Foundation

/// Presentation can revoke a catalog command until its callback-free store transaction admits it.
/// Accepted selection is never undone by a later UI cancellation.
public final class CatalogSelectionAdmission: @unchecked Sendable {
    public enum State: Sendable { case pending, revoked, admitted }
    private let lock = NSLock()
    private var value: State = .pending
    public init() {}
    public var state: State { lock.withLock { value } }
    @discardableResult
    public func revoke() -> Bool {
        lock.withLock {
            guard value == .pending else { return false }
            value = .revoked
            return true
        }
    }
    func admit() -> Bool {
        lock.withLock {
            guard value == .pending else { return false }
            value = .admitted
            return true
        }
    }
}
