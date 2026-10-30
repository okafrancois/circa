import AppKit
import BrowserEngine
import ObjectiveC.runtime

/// Keep Chromium's native drag destination and intercept only completed file drops. A hover
/// never grants access, and renderer navigation callbacks cannot enter this native boundary.
@MainActor
enum ChromiumFileDrop {
    private static var installed: Set<ObjectIdentifier> = []

    static func install(in view: NSView) {
        let selector = #selector(NSView.performDragOperation(_:))
        let type: AnyClass = object_getClass(view)!
        let identity = ObjectIdentifier(type)
        if !installed.contains(identity), let method = class_getInstanceMethod(type, selector) {
            installed.insert(identity)
            let original = method_getImplementation(method)
            typealias Perform = @convention(c) (AnyObject, Selector, AnyObject) -> ObjCBool
            let perform = unsafeBitCast(original, to: Perform.self)
            let block: @convention(block) (NSView, AnyObject) -> ObjCBool = { target, sender in
                MainActor.assumeIsolated {
                    var ancestor: NSView? = target
                    while let candidate = ancestor, !(candidate is ChromiumHostView) { ancestor = candidate.superview }
                    if let host = ancestor as? ChromiumHostView, let surface = host.surface,
                       let info = sender as? any NSDraggingInfo {
                        let files = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                        if !files.isEmpty {
                            return ObjCBool(surface.delegate?.surface(surface, openDroppedFiles: files) ?? false)
                        }
                    }
                    return perform(target, selector, sender)
                }
            }
            let replacement = imp_implementationWithBlock(block)
            if !class_addMethod(type, selector, replacement, method_getTypeEncoding(method)) {
                class_replaceMethod(type, selector, replacement, method_getTypeEncoding(method))
            }
        }
        for child in view.subviews { install(in: child) }
    }
}
