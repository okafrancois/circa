import BrowserCore
import BrowserEngine
import Foundation
import WebKit

/// Session-only site zoom for WebKit, which has no per-site zoom of its own. Scoped by profile and
/// host, like Chromium's per-profile host zoom; engines with `nativeSiteZoom` do not need it.
@MainActor
final class WebKitPageZoomStore {

    private struct Site: Hashable {
        let profileID: ProfileID
        let host: String
    }

    private final class Reference {
        weak var surface: WebKitSurface?
        init(_ surface: WebKitSurface) { self.surface = surface }
    }

    private let policy = try! BrowserPageZoom()
    private var factors: [Site: Double] = [:]
    private var surfaces: [Reference] = []

    func register(_ surface: WebKitSurface) {
        surfaces.removeAll { $0.surface == nil }
        guard !surfaces.contains(where: { $0.surface === surface }) else { return }
        surfaces.append(Reference(surface))
    }

    func documentDidCommit(_ surface: WebKitSurface) {
        surface.webView.pageZoom = site(for: surface).flatMap { factors[$0] } ?? policy.resetFactor
        surface.onChange?()
    }

    func perform(_ command: BrowserPageZoomCommand, on surface: WebKitSurface) {
        let current = surface.webView.pageZoom
        let next: Double
        do {
            switch command {
            case .increase: next = try policy.nextFactor(after: current)
            case .decrease: next = try policy.previousFactor(before: current)
            case .reset: next = policy.resetFactor
            }
        } catch { return }
        guard let site = site(for: surface) else {
            surface.webView.pageZoom = next
            surface.onChange?()
            return
        }
        factors[site] = next == policy.resetFactor ? nil : next
        surfaces.removeAll { $0.surface == nil }
        for reference in surfaces {
            guard let candidate = reference.surface, self.site(for: candidate) == site else { continue }
            candidate.webView.pageZoom = next
            candidate.onChange?()
        }
    }

    func removeProfile(_ profileID: ProfileID) {
        factors = factors.filter { $0.key.profileID != profileID }
        surfaces.removeAll { $0.surface == nil || $0.surface?.profileID == profileID }
    }

    private func site(for surface: WebKitSurface) -> Site? {
        guard let url = surface.committedURL, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return Site(profileID: surface.profileID, host: host)
    }
}
