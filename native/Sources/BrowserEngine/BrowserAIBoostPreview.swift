import Foundation

/// Optional main-document capability. A lease never enters the saved Boost registry.
@MainActor public protocol BrowserAIBoostPreview: AnyObject {
    func readBoostStructure(revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> String
    func previewBoostCSS(_ css: String, lease: UUID, revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool
    func validateBoostJavaScript(_ source: String, revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool
    func clearBoostPreview(lease: UUID, revision: UInt64) async
}

public extension BrowserAIBoostPreview {
    func validateBoostJavaScript(_ source: String, revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool { false }
}
