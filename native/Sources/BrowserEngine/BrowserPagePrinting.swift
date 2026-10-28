import AppKit

/// Optional engine service. Printing is available only when both this service and the printing
/// capability are present; the shell never prints a wrapper view in place of its document.
@MainActor
public protocol BrowserPagePrinting<Surface>: AnyObject {
    associatedtype Surface: BrowserEngineSurface
    func printPage(_ surface: Surface) throws
}
