import Foundation

/// Optional page-data capability. Implementations read in an isolated world and validate
/// document identity on both sides of every asynchronous operation.
@MainActor public protocol BrowserAIPageReading: AnyObject {
    func highlightAIPassage(_ passage: String, revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool
    func readAIPage(revision: UInt64, isCurrent: @escaping @MainActor () -> Bool) async throws -> String
}
