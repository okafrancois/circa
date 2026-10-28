import AppKit

/// Capture before the single AppKit layout, then animate the backing geometry at commit time.
/// The document is resized only to its final viewport. Neither a delayed main-run-loop callback
/// nor preparing its backing store consumes part of the 80 ms compositor animation.
@MainActor
struct OrbitSidebarLayerTransition {
    private struct State {
        let layer: CALayer
        let position: CGPoint
        let bounds: CGRect
        let displayedPosition: CGPoint
        let displayedBounds: CGRect
    }
    private var states: [State] = []

    init(roots: [CALayer?]) {
        func visit(_ layer: CALayer) {
            let positionIsAnimating = layer.animation(forKey: "orbit.sidebar.position") != nil
            let boundsAreAnimating = layer.animation(forKey: "orbit.sidebar.bounds") != nil
            let displayed = positionIsAnimating || boundsAreAnimating ? layer.presentation() : nil
            // A newly unhidden/offscreen-prepared layer can still expose the previous commit's
            // presentation. Only an interrupted flight needs that value; otherwise use the model.
            states.append(State(layer: layer, position: layer.position, bounds: layer.bounds,
                displayedPosition: positionIsAnimating ? (displayed?.position ?? layer.position) : layer.position,
                displayedBounds: boundsAreAnimating ? (displayed?.bounds ?? layer.bounds) : layer.bounds))
            for child in layer.sublayers ?? [] { visit(child) }
        }
        for root in roots.compactMap({ $0 }) { visit(root) }
    }

    @discardableResult
    func animate(spring: OrbitTokens.Spring?) -> Int {
        var count = 0
        for state in states {
            let layer = state.layer
            if state.position != layer.position {
                add(to: layer, key: "position", from: NSValue(point: state.displayedPosition),
                    target: NSValue(point: layer.position), spring: spring)
                count += 1
            }
            if state.bounds != layer.bounds {
                add(to: layer, key: "bounds", from: NSValue(rect: state.displayedBounds),
                    target: NSValue(rect: layer.bounds), spring: spring)
                count += 1
            }
        }
        return count
    }

    func cancel() {
        for state in states {
            state.layer.removeAnimation(forKey: "orbit.sidebar.position")
            state.layer.removeAnimation(forKey: "orbit.sidebar.bounds")
        }
    }

    private func add(to layer: CALayer, key: String, from: NSValue, target: NSValue, spring: OrbitTokens.Spring?) {
        let animation: CABasicAnimation
        if let spring { animation = spring.animation(keyPath: key) }
        else {
            animation = CABasicAnimation(keyPath: key)
            animation.duration = OrbitAnimationTiming.sidebar.duration
            animation.timingFunction = OrbitAnimationTiming.sidebar.mediaTimingFunction
        }
        animation.fromValue = from
        animation.toValue = target
        // Zero uses the transaction's commit time, rather than the time layout started.
        animation.beginTime = 0
        layer.add(animation, forKey: "orbit.sidebar." + key)
    }
}
