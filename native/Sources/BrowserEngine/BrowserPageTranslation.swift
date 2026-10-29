import Foundation

public struct BrowserTranslationText: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public struct BrowserTranslationSample: Sendable {
    public let text: String
    public let language: String
    public init(text: String, language: String) { self.text = text; self.language = language }
}
