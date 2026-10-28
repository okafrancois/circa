import AppKit
import WebKit

/// The engine view of a WebKit surface.
/// A first-responder WKWebView claims every key equivalent AppKit offers it (`true`), sends the
/// key to its web content process, and re-dispatches it through `NSApp.sendEvent` only when the
/// page answers "unhandled". Without a content process — a tab that has not loaded anything yet
/// (Orbit's blank New Tab) or whose process terminated — WebKit drops the key: the page never
/// sees it and neither does the menu, so page-first browser shortcuts such as ⌘S do nothing
/// (DBG-KEYS, VIS-2). Declining instead lets AppKit continue to the main menu exactly as for a
/// key the page did not handle. A live page keeps WebKit's page-first handling unchanged.
@MainActor
final class WebKitDocumentView: WKWebView {
    /// False until the first load starts, and again after the content process terminates.
    /// WebKit launches the process synchronously when a load is issued.
    private(set) var hasContentProcess = false

    func contentProcessDidStart() { hasContentProcess = true }
    func contentProcessDidTerminate() { hasContentProcess = false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard hasContentProcess else { return false }
        return super.performKeyEquivalent(with: event)
    }

    // Public load entry points launch (or relaunch) the content process. Others (data loads,
    // restoration, WebKit-initiated loads) are covered by the navigation callbacks. WebKit calls
    // its data load internally with a nil base URL, which a Swift override cannot accept.
    override func load(_ request: URLRequest) -> WKNavigation? {
        contentProcessDidStart()
        return super.load(request)
    }

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        contentProcessDidStart()
        return super.loadHTMLString(string, baseURL: baseURL)
    }

    override func loadFileURL(_ URL: URL, allowingReadAccessTo readAccessURL: URL) -> WKNavigation? {
        contentProcessDidStart()
        return super.loadFileURL(URL, allowingReadAccessTo: readAccessURL)
    }

    override func reload() -> WKNavigation? {
        contentProcessDidStart()
        return super.reload()
    }

    override func reloadFromOrigin() -> WKNavigation? {
        contentProcessDidStart()
        return super.reloadFromOrigin()
    }

    override func go(to item: WKBackForwardListItem) -> WKNavigation? {
        contentProcessDidStart()
        return super.go(to: item)
    }

    override func goBack() -> WKNavigation? {
        contentProcessDidStart()
        return super.goBack()
    }

    override func goForward() -> WKNavigation? {
        contentProcessDidStart()
        return super.goForward()
    }

    // Script evaluation and web archives also launch the process of a never-loaded view (measured
    // with WebKit's test SPI, DBG-KEYS-R2): a script may install a key handler or make the document
    // editable, which must then receive its keys first. Find, snapshots, PDF, media and zoom do not.
    override func evaluateJavaScript(_ javaScriptString: String,
                                     completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil) {
        contentProcessDidStart()
        super.evaluateJavaScript(javaScriptString, completionHandler: completionHandler)
    }

    // The Result-based Swift variants are overlay extensions over these refined selectors.
    override func __evaluateJavaScript(_ javaScriptString: String, inFrame frame: WKFrameInfo?, in contentWorld: WKContentWorld,
                                       completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil) {
        contentProcessDidStart()
        super.__evaluateJavaScript(javaScriptString, inFrame: frame, in: contentWorld, completionHandler: completionHandler)
    }

    override func __callAsyncJavaScript(_ functionBody: String, arguments: [String: Any]?, inFrame frame: WKFrameInfo?,
                                        in contentWorld: WKContentWorld,
                                        completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil) {
        // WebKit rejects unsupported argument objects before launching a process. Keep its own
        // validation/error delivery, but only record a launch for its public supported types.
        let startsProcess = arguments?.values.allSatisfy(Self.isSupportedJavaScriptArgument) ?? true
        super.__callAsyncJavaScript(functionBody, arguments: arguments, inFrame: frame, in: contentWorld,
                                    completionHandler: completionHandler)
        if startsProcess { contentProcessDidStart() }
    }

    /// WKWebView.h permits NSNumber, NSString, NSDate, NSArray, NSDictionary and NSNull;
    /// container contents include dictionary keys. Native argument rejection precedes launch,
    /// unlike a JavaScript syntax/runtime error. Track container identities to handle cycles
    /// and shared references without recursive traversal or a second validation stack overflow.
    private static func isSupportedJavaScriptArgument(_ value: Any) -> Bool {
        var pending = [value]
        // Retain bridged containers as well as their identities: temporary NSArray bridges
        // must not deallocate and let a different container reuse an already visited address.
        var visited: [ObjectIdentifier: AnyObject] = [:]
        while let next = pending.popLast() {
            switch next {
            case is NSNumber, is NSString, is NSDate, is NSNull:
                continue
            case let array as NSArray:
                guard visited.updateValue(array, forKey: ObjectIdentifier(array)) == nil else { continue }
                pending.append(contentsOf: array)
            case let dictionary as NSDictionary:
                guard visited.updateValue(dictionary, forKey: ObjectIdentifier(dictionary)) == nil else { continue }
                for (key, value) in dictionary {
                    pending.append(key)
                    pending.append(value)
                }
            default:
                return false
            }
        }
        return true
    }

    override func __createWebArchiveData(completionHandler: @escaping @MainActor @Sendable (Data?, (any Error)?) -> Void) {
        contentProcessDidStart()
        super.__createWebArchiveData(completionHandler: completionHandler)
    }
}
