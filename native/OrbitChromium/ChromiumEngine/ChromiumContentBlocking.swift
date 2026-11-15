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

    public var supportsPrivateWindows: Bool {
        guard let engine, !engine.isShutDown else { return false }
        return ACRContentBlockingPrivateAvailable() == 1
    }

    /// The initial profile's copy of the extension runs one split-mode worker per private context;
    /// it must be loaded with incognito access before the context exists. At launch the copy may
    /// still be loading, so this retries (bounded) until it is in place.
    public func preparePrivateWindows() async throws {
        guard let engine else { throw BrowserEngineError.unsupportedOperation }
        let deadline = ContinuousClock.now + .seconds(3)
        while ACRContentBlockingPreparePrivate() != 1 {
            guard ContinuousClock.now < deadline, !engine.isShutDown else { throw BrowserEngineError.unsupportedOperation }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Writes the configuration to every open private context's own (memory-only) cookie store.
    /// There is no synchronous off switch here: the shared copy keeps running for the open
    /// contexts, so disabling also waits for the workers when asked.
    public func configurePrivateWindows(_ configuration: BrowserContentBlockingConfiguration,
                                        waitsForAcknowledgement: Bool) async throws {
        guard let engine, !engine.isShutDown else { throw BrowserEngineError.unsupportedOperation }
        revision += 1
        let current = revision
        let enabled = configuration.isEnabled ? 1 : 0
        guard ACRContentBlockingConfigurePrivate(Int32(enabled), configuration.allowedHosts.joined(separator: "|"), current) == 1 else {
            throw BrowserEngineError.unsupportedOperation
        }
        guard waitsForAcknowledgement else { return }
        let deadline = ContinuousClock.now + .seconds(3)
        var pending = Set(privateContexts())
        while !pending.isEmpty, ContinuousClock.now < deadline, !engine.isShutDown {
            for token in pending {
                let value = await acknowledgement { ACRContentBlockingPrivateAcknowledgement(token, $0, $1) }
                if value == "\(current).\(enabled)" { pending.remove(token) }
            }
            if !pending.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        }
    }

    public func endPrivateWindowSession() {
        guard let engine, !engine.isShutDown else { return }
        _ = ACRContentBlockingEndPrivateSession()
    }

    private func privateContexts() -> [UInt64] {
        var tokens = [UInt64](repeating: 0, count: 16)
        let count = Int(ACRContentBlockingPrivateContextList(&tokens, Int32(tokens.count)))
        if count > tokens.count {
            tokens = [UInt64](repeating: 0, count: count)
            _ = ACRContentBlockingPrivateContextList(&tokens, Int32(count))
        }
        return Array(tokens.prefix(max(0, count)))
    }

    /// The extension's last applied "<revision>.<enabled>", nil before any.
    public func acknowledgement(profileID: ProfileID) async -> String? {
        guard let engine else { return nil }
        return await acknowledgement(token: engine.profileToken(for: profileID))
    }

    private func acknowledgement(token: UInt64) async -> String? {
        await acknowledgement { ACRContentBlockingAcknowledgement(token, $0, $1) }
    }

    /// Each open private context's last applied "<revision>.<enabled>" ("none" before any).
    public func privateAcknowledgements() async -> [String] {
        var values: [String] = []
        for token in privateContexts() {
            values.append(await acknowledgement { ACRContentBlockingPrivateAcknowledgement(token, $0, $1) } ?? "none")
        }
        return values
    }

    private func acknowledgement(_ read: (orbit_content_blocking_ack_t, UnsafeMutableRawPointer) -> Int32) async -> String? {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(AcknowledgementBox(continuation))
            let accepted = read({ context, value in
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
