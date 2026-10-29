import AppKit
import ObjectiveC

/// Space pages slide by moving their native frames, so hit testing, accessibility frames,
/// tracking areas and scroll coordinates follow the visible controls at every frame. AppKit
/// otherwise redraws every drawing view that may paint outside its bounds whenever its window
/// position changes. While a slide runs, those leaf views clip to their own bounds, so their
/// layers are composited at each new position; at rest the original clipping returns and AppKit
/// redraws them once at the settled position.
@MainActor
final class SpacePageCompositing {
    private struct Entry {
        weak var view: NSView?
    }
    private var roots: Set<ObjectIdentifier> = []
    private var entries: [ObjectIdentifier: Entry] = [:]
    var isActive: Bool { !roots.isEmpty }
    var clippedViews: [NSView] { entries.values.compactMap(\.view) }
    var clippedViewCount: Int { clippedViews.count }

    /// Clip the drawing leaves below `root` while it moves. Called for every moved frame: rows a page
    /// lays out after its first move, or restores from a preview raster, join on their next frame.
    func include(_ root: NSView) {
        roots.insert(ObjectIdentifier(root))
        clipLeaves(below: root)
    }

    /// Return every clipped view to its own drawing at its current (settled) position.
    func restore() {
        guard isActive else { return }
        let views = entries.values.compactMap(\.view)
        roots.removeAll()
        entries.removeAll()
        for view in views where view.clipsToBounds { view.clipsToBounds = false }
    }

    private func clipLeaves(below view: NSView) {
        for child in view.subviews {
            if child.subviews.isEmpty {
                if !child.clipsToBounds, Self.draws(child) {
                    entries[ObjectIdentifier(child)] = Entry(view: child)
                    child.clipsToBounds = true
                }
            } else {
                clipLeaves(below: child)
            }
        }
    }

    private static var drawingClasses: [ObjectIdentifier: Bool] = [:]
    /// Only views that paint through `draw(_:)` hold position-tracked backing stores. Layer-hosting
    /// views, `updateLayer` views (labels, images) and containers keep their own layers untouched.
    private static func draws(_ view: NSView) -> Bool {
        if view.wantsUpdateLayer { return false }
        if let layer = view.layer, layer.delegate !== view { return false }
        let type: AnyClass = Swift.type(of: view)
        let key = ObjectIdentifier(type)
        if let cached = drawingClasses[key] { return cached }
        let selector = #selector(NSView.draw(_:))
        let draws = class_getMethodImplementation(type, selector) != class_getMethodImplementation(NSView.self, selector)
        drawingClasses[key] = draws
        return draws
    }
}
