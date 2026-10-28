import AppKit
import BrowserEngine

extension WebKitBrowserEngine: BrowserPagePrinting {
    public func printPage(_ surface: WebKitSurface) throws {
        try surface.perform(.print)
    }
}
