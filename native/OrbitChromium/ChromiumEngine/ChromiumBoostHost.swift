import BrowserCore
import BrowserEngine
import Foundation
import OrbitChromiumBridge

/// Sources go only to the browser-owned registry. No DevTools or page-world fallback.
@MainActor
final class ChromiumBoostHost: BrowserBoostHost {
    private weak var engine: ChromiumBrowserEngine?
    init(engine: ChromiumBrowserEngine) { self.engine = engine }

    func replaceBoosts(_ payload: BrowserBoostProfilePayload) async throws -> BrowserBoostAcknowledgement {
        guard let engine, engine.boosts != nil else { throw BrowserEngineError.unsupportedOperation }
        await engine.profileReady(payload.profileID)
        guard !engine.refusedProfiles.contains(payload.profileID) else { throw BrowserEngineError.unsupportedOperation }
        let rows: [[String: Any]] = payload.boosts.map { boost in
            ["id": boost.id.rawValue.uuidString.lowercased(), "revision": String(boost.revision),
             "host": boost.hostPattern.host, "schemes": boost.hostPattern.schemes.map(\.rawValue).sorted(),
             "subdomains": boost.hostPattern.includesSubdomains, "port": boost.hostPattern.port ?? 0,
             "css": boost.css, "js": boost.isolatedJavaScript ?? ""]
        }
        let data = try JSONSerialization.data(withJSONObject: ["revision": String(payload.revision), "boosts": rows], options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        let installed: Int32 = await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(BoostCompletion(continuation, revision: payload.revision))
            let accepted = ACRBoostsReplace(engine.profileToken(for: payload.profileID), json, payload.revision, { context, revision, installed in
                guard let context else { return }
                let completion = Unmanaged<BoostCompletion>.fromOpaque(context).takeRetainedValue()
                completion.continuation.resume(returning: installed == 1 && revision == completion.revision ? 1 : -1)
            }, box.toOpaque())
            if accepted != 1 { box.takeRetainedValue().continuation.resume(returning: 0) }
        }
        guard installed != 0 else { throw BrowserBoostError.staleRevision }
        guard installed == 1 else { throw BrowserBoostError.unavailable }
        return .init(profileID: payload.profileID, revision: payload.revision)
    }

    func removeBoosts(profileID: ProfileID, revision: UInt64) async throws -> BrowserBoostAcknowledgement {
        try await replaceBoosts(.init(profileID: profileID, revision: revision, boosts: []))
    }
}

private final class BoostCompletion {
    let continuation: CheckedContinuation<Int32, Never>
    let revision: UInt64
    init(_ continuation: CheckedContinuation<Int32, Never>, revision: UInt64) {
        self.continuation = continuation
        self.revision = revision
    }
}
