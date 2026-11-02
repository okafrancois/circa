import Foundation
import BrowserCore

/// Optional browser-only task capability. Target UUIDs refer to engine-retained DOM nodes in an
/// isolated main-frame world. Implementations never evaluate selectors or script from a model.
@MainActor public protocol BrowserAIErrandPageReading: AnyObject {
    func observeErrandPage(tabID: UUID, revision: UInt64,
                           isCurrent: @escaping @MainActor () -> Bool) async throws -> BrowserAIErrandPage

    /// Verifies the retained target and current form values before showing its approval outline.
    func highlightErrandTarget(_ target: UUID, page: BrowserAIErrandPage, color: String, ink: String, provider: String, reducedMotion: Bool,
                               isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool

    /// Revalidates document, exact retained node, attributes, form and value snapshot immediately
    /// before dispatch. A target lease is consumed before dispatch and cannot execute twice.
    func executeErrandAction(_ action: BrowserAIErrandAction, page: BrowserAIErrandPage,
                             isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool

    func clearErrandTarget(snapshot: UUID) async
}
