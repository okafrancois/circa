import BrowserCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The system's on-device model (FoundationModels, macOS 26 and later). The framework is weakly
/// linked: on macOS 15 it is absent and the provider reports "unavailable".
final class OrbitOnDeviceAIClient: BrowserAIProviderClient, Sendable {
    let id = BrowserAIProviderID.onDevice

    static func availability() -> BrowserAIOnDeviceAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
            case .unavailable(.deviceNotEligible): return .deviceNotEligible
            case .unavailable: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        }
        #endif
        return .systemTooOld
    }

    func status(refresh: Bool) async -> BrowserAIProviderStatus {
        BrowserAIProviderStatus(id: id, state: Self.availability().state)
    }

    func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        let availability = Self.availability()
        guard availability == .available else {
            if case .unavailable(let reason) = availability.state { return .failed(.unavailable(reason)) }
            return .failed(.failed)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return Self.stream(request) }
        #endif
        return .failed(.unavailable(.systemTooOld))
    }

    func shutdown() async {}

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func stream(_ request: BrowserAITurnRequest) -> BrowserAITurn {
        let (events, continuation) = AsyncStream.makeStream(of: BrowserAITurnEvent.self, bufferingPolicy: .unbounded)
        let task = Task {
            let session = LanguageModelSession(instructions: request.instructions)
            var previous = ""
            do {
                // Snapshots carry the whole answer so far; emit only what is new.
                for try await snapshot in session.streamResponse(to: request.prompt) {
                    let content = snapshot.content
                    let delta = content.hasPrefix(previous) ? String(content.dropFirst(previous.count)) : content
                    previous = content
                    if !delta.isEmpty { continuation.yield(.text(delta)) }
                }
                continuation.yield(Task.isCancelled ? .interrupted : .completed)
            } catch {
                continuation.yield(Task.isCancelled || error is CancellationError ? .interrupted : .failed(.failed))
            }
            continuation.finish()
        }
        return BrowserAITurn(events: events) { task.cancel() }
    }
    #endif
}
