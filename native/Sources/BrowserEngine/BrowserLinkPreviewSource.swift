import Foundation

public struct BrowserLinkPreviewTarget: Equatable, Sendable {
    public let id: String
    public let url: URL
    public let title: String
    public let description: String
    public let bounds: CGRect
    public init(id: String, url: URL, title: String, description: String, bounds: CGRect) {
        self.id = id; self.url = url; self.title = title; self.description = description; self.bounds = bounds
    }
}

/// Passive main-frame hit testing. No link activation, navigation or page scripts are exposed.
@MainActor public protocol BrowserLinkPreviewSource: AnyObject {
    func previewLink(at point: CGPoint, revision: UInt64,
                     isCurrent: @escaping @MainActor () -> Bool) async throws -> BrowserLinkPreviewTarget?
}
