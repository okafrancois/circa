import BrowserCore
import BrowserEngine
import Foundation
import OrbitChromiumBridge

/// Built-in blocking through the app's bundled declarativeNetRequest extension, which the engine
/// loads as a component of every regular profile and configures in the browser process. The
/// extension is internal: `ChromiumExtensionHost` never lists or mutates it.
@MainActor
public final class ChromiumContentBlocking: BrowserContentBlocking {
    public static let extensionID = String(cString: ACRContentBlockingExtensionID())
    private weak var engine: ChromiumBrowserEngine?
    /// The engine's last completion per profile and for private windows: 1 applied, -1 failed.
    private var statuses: [ProfileID: Int32] = [:]
    private var privateStatus: Int32?
    init(engine: ChromiumBrowserEngine) { self.engine = engine }

    public func configure(_ configuration: BrowserContentBlockingConfiguration, profileID: ProfileID,
                          waitsForAcknowledgement: Bool) async throws {
        guard let engine else { throw BrowserEngineError.unsupportedOperation }
        await engine.profileReady(profileID)
        guard !engine.isShutDown, !engine.refusedProfiles.contains(profileID) else {
            throw BrowserEngineError.unsupportedOperation
        }
        let token = engine.profileToken(for: profileID)
        let enabled: Int32 = configuration.isEnabled ? 1 : 0
        let hosts = configuration.allowedHosts.joined(separator: "|")
        // Disabling always waits, so that it is in effect when this returns.
        let status = try await run(waits: waitsForAcknowledgement || !configuration.isEnabled) { [weak self] status in
            self?.statuses[profileID] = status
        } call: { ACRContentBlockingConfigure(token, enabled, hosts, $0, $1) }
        if status == -1 { throw BrowserEngineError.unsupportedOperation }
    }

    public var supportsPrivateWindows: Bool {
        guard let engine, !engine.isShutDown else { return false }
        return ACRContentBlockingPrivateAvailable() == 1
    }

    /// Replaces the shared configuration of the private windows. Nothing of it reaches disk.
    public func configurePrivateWindows(_ configuration: BrowserContentBlockingConfiguration,
                                        waitsForAcknowledgement: Bool) async throws {
        guard let engine, !engine.isShutDown else { throw BrowserEngineError.unsupportedOperation }
        let enabled: Int32 = configuration.isEnabled ? 1 : 0
        let hosts = configuration.allowedHosts.joined(separator: "|")
        let status = try await run(waits: waitsForAcknowledgement) { [weak self] status in
            self?.privateStatus = status
        } call: { ACRContentBlockingConfigurePrivate(enabled, hosts, $0, $1) }
        if status == -1 { throw BrowserEngineError.unsupportedOperation }
    }

    public func endPrivateWindowSession() {
        guard let engine, !engine.isShutDown else { return }
        privateStatus = nil
        _ = ACRContentBlockingEndPrivateSession()
    }

    /// The engine's last completion for the profile ("1" applied, "-1" failed), nil before any.
    public func acknowledgement(profileID: ProfileID) -> String? { statuses[profileID].map(String.init) }

    /// The private windows' last completion ("none" before any).
    public func privateAcknowledgements() -> [String] { [privateStatus.map(String.init) ?? "none"] }

    /// Starts one engine update. With `waits`, returns its status (nil after a short bound);
    /// otherwise returns at once. `completed` records every status that arrives.
    private func run(waits: Bool, completed: @escaping @MainActor (Int32) -> Void,
                     call: (orbit_status_callback_t, UnsafeMutableRawPointer) -> Int32) async throws -> Int32? {
        let box = ContentBlockingCompletion(completed)
        let context = Unmanaged.passRetained(box).toOpaque()
        let accepted = call({ context, status in
            guard let context else { return }
            let box = Unmanaged<ContentBlockingCompletion>.fromOpaque(context).takeRetainedValue()
            MainActor.assumeIsolated { box.complete(status) }
        }, context)
        guard accepted == 1 else {
            Unmanaged<ContentBlockingCompletion>.fromOpaque(context).release()
            throw BrowserEngineError.unsupportedOperation
        }
        guard waits else { return nil }
        return await box.wait(for: .seconds(2))
    }
}

/// One engine completion, delivered on the main thread exactly once for an accepted call.
@MainActor
private final class ContentBlockingCompletion {
    private let completed: @MainActor (Int32) -> Void
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32?, Never>?
    init(_ completed: @escaping @MainActor (Int32) -> Void) { self.completed = completed }

    func complete(_ status: Int32) {
        self.status = status
        completed(status)
        continuation?.resume(returning: status)
        continuation = nil
    }

    func wait(for bound: Duration) async -> Int32? {
        if let status { return status }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: bound)
                guard let self, let pending = self.continuation else { return }
                self.continuation = nil
                pending.resume(returning: nil)
            }
        }
    }
}
