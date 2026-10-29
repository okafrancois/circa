import AppKit

/// Workspace notification tokens retain their owning center.
final class OrbitWorkspaceObservers: @unchecked Sendable {
    var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    deinit { for (center, token) in tokens { center.removeObserver(token) } }
}
