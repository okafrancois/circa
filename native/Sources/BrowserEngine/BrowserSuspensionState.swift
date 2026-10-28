import Foundation

/// Only non-content metadata crosses the engine boundary; native session state stays in-engine. A nil result means that this document
/// is busy, has unsaved edits or cannot be checked safely; the owner keeps its engine alive.
public struct BrowserSuspensionState: Equatable, Sendable {
    public let url: URL
    public let documentGeneration: UInt64
    public let scrollX: Double
    public let scrollY: Double
    public let history: [URL]
    public let historyIndex: Int

    public init(url: URL, documentGeneration: UInt64, scrollX: Double, scrollY: Double,
                history: [URL] = [], historyIndex: Int = 0) {
        self.url = url
        self.documentGeneration = documentGeneration
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.history = history
        self.historyIndex = historyIndex
    }
}
