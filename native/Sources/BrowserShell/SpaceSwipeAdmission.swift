import Foundation

/// A release can be revoked until the store admits it. Admission is the explicit linearization
/// boundary: after it, cancelling presentation cannot undo an already admitted Space selection.
public final class SpaceSwipeAdmission: @unchecked Sendable {
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
