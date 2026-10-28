import AppKit
import Carbon.HIToolbox

/// Open requests (URLs, documents) that reach the process before its application delegate exists
/// (CHROMIUM-APP). A Chromium build sets `NSApp.delegate` only when CEF is ready; AppKit would
/// otherwise drop a cold-launch `GURL` or `odoc` event sent as the first event of a
/// default-browser launch. The queue owns both Apple Event handlers from before the runtime starts,
/// reasserts them after AppKit's `finishLaunching` and after the runtime is ready (in case either
/// installed its own), keeps requests in arrival order, and forwards them to the delegate's
/// `application(_:open:)` once `deliver(to:)` names it.
@MainActor
final class ColdLaunchOpenQueue: NSObject {
    static let shared = ColdLaunchOpenQueue()

    private(set) var pending: [URL] = []
    private weak var application: NSApplication?
    private weak var delegate: NSApplicationDelegate?
    private var launchObserver: NSObjectProtocol?

    /// Installs the handlers now and again when AppKit finishes launching.
    func install() {
        installHandlers()
        guard launchObserver == nil else { return }
        launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willFinishLaunchingNotification, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { ColdLaunchOpenQueue.shared.installHandlers() } }
    }

    func installHandlers() {
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
                                forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        manager.setEventHandler(self, andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
                                forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    /// From now on requests go to `delegate`; queued ones first, in order.
    func deliver(to delegate: NSApplicationDelegate, application: NSApplication) {
        installHandlers()
        self.delegate = delegate
        self.application = application
        flush()
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        enqueue([url])
    }

    @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }
        var urls: [URL] = []
        let count = list.numberOfItems
        if count == 0, let url = Self.fileURL(list) { urls.append(url) }
        if count > 0 {
            for index in 1...count { if let item = list.atIndex(index), let url = Self.fileURL(item) { urls.append(url) } }
        }
        enqueue(urls)
    }

    private static func fileURL(_ descriptor: NSAppleEventDescriptor) -> URL? {
        if let url = descriptor.fileURLValue { return url }
        return descriptor.coerce(toDescriptorType: DescType(typeFileURL))?.fileURLValue
    }

    private func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending.append(contentsOf: urls)
        flush()
    }

    private func flush() {
        guard let delegate, let application, !pending.isEmpty,
              delegate.responds(to: #selector(NSApplicationDelegate.application(_:open:))) else { return }
        let urls = pending
        pending.removeAll()
        delegate.application?(application, open: urls)
    }
}
