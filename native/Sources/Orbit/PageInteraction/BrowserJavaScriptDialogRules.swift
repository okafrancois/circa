import Foundation

struct BrowserJavaScriptDialogRules {
    static let expectedDelay: Duration = .seconds(1)

    struct Document: Hashable {
        let surface: ObjectIdentifier
        let generation: UInt64
    }

    enum Decision: Equatable {
        case suppress
        case show(offersPrevention: Bool)
    }

    private var showing: Set<ObjectIdentifier> = []
    private var prevented: Set<Document> = []
    private var lastClosed: [ObjectIdentifier: (generation: UInt64, at: ContinuousClock.Instant)] = [:]

    mutating func decide(for document: Document, isBeforeUnload: Bool, now: ContinuousClock.Instant) -> Decision {
        if showing.contains(document.surface) || prevented.contains(document) { return .suppress }
        showing.insert(document.surface)
        guard !isBeforeUnload, let closed = lastClosed[document.surface], closed.generation == document.generation else {
            return .show(offersPrevention: false)
        }
        return .show(offersPrevention: closed.at.duration(to: now) < Self.expectedDelay)
    }

    mutating func didClose(_ document: Document, preventingFurther: Bool, now: ContinuousClock.Instant) {
        showing.remove(document.surface)
        lastClosed[document.surface] = (document.generation, now)
        if preventingFurther { prevented.insert(document) }
    }

    /// The engine dropped the surface's dialogs (navigation, renderer gone) or the surface went away.
    mutating func reset(_ surface: ObjectIdentifier, keepingGeneration generation: UInt64? = nil) {
        showing.remove(surface)
        prevented = prevented.filter { $0.surface != surface || $0.generation == generation }
        if lastClosed[surface]?.generation != generation { lastClosed[surface] = nil }
    }

    func isShowing(_ surface: ObjectIdentifier) -> Bool { showing.contains(surface) }
    func isPrevented(_ document: Document) -> Bool { prevented.contains(document) }
}
