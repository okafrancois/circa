import Foundation

/// An opaque editable-selection lease. Text and geometry belong to one document revision.
public struct BrowserAIWritingSelection: Equatable, Sendable {
    public let token: String
    public let text: String
    public let bounds: CGRect
    public init(token: String, text: String, bounds: CGRect) {
        self.token = token
        self.text = text
        self.bounds = bounds
    }
}

@MainActor public protocol BrowserAIWriting: AnyObject {
    func writingSelection(revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> BrowserAIWritingSelection?
    func applyWriting(_ text: String, selection: BrowserAIWritingSelection, insertBelow: Bool,
                      revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool
}
