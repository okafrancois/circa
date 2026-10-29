import Foundation
import NaturalLanguage

struct BrowserTranslationState: Equatable {
    enum Phase: Equatable { case unavailable, available, translating, translated, original, failed }
    private(set) var phase: Phase = .unavailable
    private(set) var source = ""
    private(set) var target = ""

    mutating func detect(source: String?, preferred: [String], supported: Bool) {
        guard let source = source.flatMap(Self.languageCode),
              let target = preferred.first.flatMap(Self.languageCode), supported,
              !preferred.compactMap(Self.languageCode).contains(source) else { phase = .unavailable; return }
        self.source = source; self.target = target; phase = .available
    }
    mutating func begin() -> Bool {
        guard [.available, .original, .failed].contains(phase) else { return false }
        phase = .translating; return true
    }
    mutating func complete() { if phase == .translating { phase = .translated } }
    mutating func restore() { if [.translated, .translating, .failed].contains(phase) { phase = .original } }
    mutating func fail() { phase = .failed }
    static func languageCode(_ identifier: String) -> String? {
        let language = Locale.Language(identifier: identifier).languageCode?.identifier
        return language.flatMap { ["und", "mul", "zxx"].contains($0) || $0.isEmpty ? nil : $0 }
    }
    static func detectLanguage(text: String, hint: String) -> String? {
        guard text.count >= 40 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        if let best = hypotheses.first, best.value >= 0.65 { return best.key.rawValue }
        return languageCode(hint)
    }
}
