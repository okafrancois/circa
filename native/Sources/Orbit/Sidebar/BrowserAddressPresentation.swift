import BrowserEngine
import Foundation

/// The resting address is a native committed identity, never an entry draft or pending URL.
struct BrowserAddressPresentation: Equatable {
    let value: String
    let label: String
    let connection: BrowserSiteControlsModel.Connection

    @MainActor
    init<Surface: BrowserEngineSurface>(surface: Surface?) {
        let services = surface?.nativePageServices
        let url = services != nil ? services?.committedURL() : surface?.navigationState.committedURL
        self.init(url: url, security: services?.securityState(), format: { url in
            services?.securityDisplay(for: url, scheme: .omitHTTPAndHTTPS)
        })
    }

    init(url: URL?, security: BrowserPageSecurityState?, format: (URL) -> String?) {
        guard let url else { value = ""; label = ""; connection = .unavailable; return }
        let scheme = url.scheme?.lowercased()
        // Only hierarchical web identities can expose an address. Non-web and opaque URLs
        // are redacted in the editor and accessibility value as well as the resting label.
        guard ["http", "https"].contains(scheme ?? ""), url.host?.isEmpty == false else {
            value = uiText("Page"); label = value; connection = .unavailable; return
        }
        value = url.absoluteString
        connection = BrowserSiteControlsModel.Connection.resolve(url: url, security: security)
        // A failed formatter must not fall back to a Unicode/renderer-derived host.
        label = format(url).flatMap { $0.isEmpty ? nil : $0 } ?? uiText("Page")
    }
}

/// A single selected-surface subscription; replacement and teardown cancel the old stream.
@MainActor
final class BrowserSecurityObservation {
    private weak var services: (any BrowserNativePageServices)?
    private var task: Task<Void, Never>?
    func observe(_ services: (any BrowserNativePageServices)?, changed: @escaping @MainActor () -> Void) {
        guard self.services !== services else { return }
        task?.cancel()
        self.services = services
        guard let services else { task = nil; return }
        var previous = services.securityState()
        let changes = services.securityChanges()
        task = Task { [weak self, weak services] in
            for await state in changes {
                guard !Task.isCancelled, let self, self.services === services else { return }
                guard state != previous else { continue }
                previous = state
                changed()
            }
        }
    }
    deinit { task?.cancel() }
}
