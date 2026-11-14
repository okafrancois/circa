import BrowserCore
import BrowserEngine
import Foundation
import OrbitChromiumBridge

/// Built-in blocking through the app's bundled declarativeNetRequest extension. The extension is
/// internal: `ChromiumExtensionHost` never lists or mutates it.
@MainActor
public final class ChromiumContentBlocking: BrowserContentBlocking {
    public static let extensionID = String(cString: ACRContentBlockingExtensionID())
    private weak var engine: ChromiumBrowserEngine?
    /// Wall-clock seeded so revisions keep increasing across launches.
    private var revision = UInt64(Date().timeIntervalSince1970 * 1000)
    init(engine: ChromiumBrowserEngine) { self.engine = engine }

    public func configure(_ configuration: BrowserContentBlockingConfiguration, profileID: ProfileID,
                   waitsForAcknowledgement: Bool) async throws {
        guard let engine else { throw BrowserEngineError.unsupportedOperation }
        await engine.profileReady(profileID)
        guard !engine.isShutDown, !engine.refusedProfiles.contains(profileID) else {
            throw BrowserEngineError.unsupportedOperation
        }
        revision += 1
        let current = revision
        let token = engine.profileToken(for: profileID)
        guard ACRContentBlockingConfigure(token, configuration.isEnabled ? 1 : 0,
                                          configuration.allowedHosts.joined(separator: "|"), current) == 1 else {
            throw BrowserEngineError.unsupportedOperation
        }
        // Disabling also disables the extension synchronously; only enabling waits for its worker.
        guard waitsForAcknowledgement, configuration.isEnabled else { return }
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, !engine.isShutDown {
            if await acknowledgement(token: token) == "\(current).1" { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The extension's last applied "<revision>.<enabled>", nil before any.
    public func acknowledgement(profileID: ProfileID) async -> String? {
        guard let engine else { return nil }
        return await acknowledgement(token: engine.profileToken(for: profileID))
    }

    private func acknowledgement(token: UInt64) async -> String? {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(AcknowledgementBox(continuation))
            let accepted = ACRContentBlockingAcknowledgement(token, { context, value in
                guard let context else { return }
                let box = Unmanaged<AcknowledgementBox>.fromOpaque(context).takeRetainedValue()
                box.continuation.resume(returning: value.map { String(cString: $0) })
            }, box.toOpaque())
            if accepted != 1 { box.takeRetainedValue().continuation.resume(returning: nil) }
        }
    }
}

private final class AcknowledgementBox {
    let continuation: CheckedContinuation<String?, Never>
    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
}
