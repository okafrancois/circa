import Foundation

// Dependency substitutes only: this fixture executes the exact extracted route bodies.
@MainActor final class Surface {
    var requests = [URL(string: "https://review.invalid/form")!]
    func navigate(to url: URL) { requests.append(url) }
}
@MainActor final class Owner {
    let source = Surface()
    var tabs: [Surface] = []
    init() { tabs = [source] }
    func submitAddress(_ text: String) { source.navigate(to: URL(string: text)!) }
    func openTab(url: URL) { let child = Surface(); child.requests = []; child.navigate(to: url); tabs.append(child) }
    func openExtensionStore(from surface: Surface) { precondition(surface === source); openTab(url: URL(string: "https://chromewebstore.google.com/")!) }
}
@MainActor final class SiteControlButton {
    let action: () -> Void
    init(_ title: String, identifier: String, action: @escaping () -> Void) { self.action = action }
}
@MainActor final class Panel { func close() {} }
func siteText(_ key: String, _ fallback: String) -> String { fallback }
@MainActor final class Controls {
    var owner: Owner?
    let panel = Panel()
    init(_ owner: Owner) { self.owner = owner }
    func row(surface: Surface, valid: @escaping () -> Bool) -> SiteControlButton {
        var rows: [SiteControlButton] = []
/* SITE ROW */
        return rows[0]
    }
}
@MainActor func add(_ controller: Owner) {
/* ADD BODY */
}
@main struct Review {
    @MainActor static func main() {
        let plus = Owner(), site = Owner()
        let initial = plus.source.requests
        add(plus)
        let controls = Controls(site)
        var current = false
        let button = controls.row(surface: site.source, valid: { current })
        button.action()
        precondition(site.tabs.count == 1 && site.source.requests == initial)
        current = true
        button.action()
        let preserved = plus.tabs.count == 2 && site.tabs.count == 2 &&
            plus.source.requests == initial && site.source.requests == initial &&
            plus.tabs.last !== plus.source && site.tabs.last !== site.source &&
            plus.tabs.last?.requests.last?.absoluteString == "https://chromewebstore.google.com/" &&
            site.tabs.last?.requests.last?.absoluteString == "https://chromewebstore.google.com/"
        print(preserved ? "PASS exact Add Extension and Site Controls route preservation" : "RED route replaces source instead of creating Store tab")
        if !preserved { exit(42) }
    }
}
