enum BrowserSplitStrings {
    static var closePane: String { uiText("Close Pane") }
    static var activePane: String { uiText("Active pane") }
    static var visiblePane: String { uiText("Visible pane") }
    static var untitledPane: String { uiText("Untitled") }
    static var notLoaded: String { uiText("Page not loaded yet") }
    static var openInAnotherWindow: String { uiText("Open in another window") }
    /// Divider label; the two numbers are the adjacent panes in layout order.
    static func dividerLabel(before: Int, after: Int) -> String {
        uiFormat("Resize panes %d and %d", before, after)
    }
    static var groupRenameRefused: String {
        uiText("A Split View is named after its pages. Rename a page instead.")
    }
}
