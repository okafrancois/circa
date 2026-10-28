import AppKit
import BrowserCore

@MainActor
enum BrowserSplitTokens {
    static let gap = OrbitTokens.Metrics.Content.splitGap
    static let borderWidth = OrbitTokens.Metrics.Content.splitFocusBorderWidth
    static let radius = OrbitTokens.Radius.splitPane
    static let toolbarHeight = OrbitTokens.Metrics.Content.splitPaneToolbarHeight
    static let minimumPaneExtent: CGFloat = 120 // estimate; scales down at smaller sizes
    static let edgeBand: CGFloat = 48 // estimate
    static let focusFade = OrbitTokens.Motion.splitFocusCrossfade
}

struct BrowserSplitGeometry {
    let panes: [CGRect]
    let dividers: [CGRect]

    /// No negative rectangles, even below the minimum size. Ratios survive tiny windows.
    static func layout(in bounds: CGRect, orientation: BrowserSplitOrientation,
                       ratios: [Double], gap: CGFloat = 10) -> BrowserSplitGeometry {
        guard !ratios.isEmpty, ratios.allSatisfy({ $0.isFinite && $0 > 0 }), gap.isFinite else { return .init(panes: [], dividers: []) }
        let horizontal = orientation == .horizontal
        let extent = max(0, horizontal ? bounds.width : bounds.height)
        let actualGap = min(max(0, gap), extent / CGFloat(max(1, ratios.count - 1)))
        let available = max(0, extent - CGFloat(ratios.count - 1) * actualGap)
        let total = ratios.reduce(0, +)
        var cursor = horizontal ? bounds.minX : bounds.minY
        var panes: [CGRect] = [], dividers: [CGRect] = []
        for (index, ratio) in ratios.enumerated() {
            let last = index == ratios.count - 1
            let size = last ? max(0, (horizontal ? bounds.maxX : bounds.maxY) - cursor) : available * ratio / total
            panes.append(horizontal ? CGRect(x: cursor, y: bounds.minY, width: size, height: max(0, bounds.height))
                                    : CGRect(x: bounds.minX, y: cursor, width: max(0, bounds.width), height: size))
            cursor += size
            if !last {
                dividers.append(horizontal ? CGRect(x: cursor, y: bounds.minY, width: actualGap, height: max(0, bounds.height))
                                           : CGRect(x: bounds.minX, y: cursor, width: max(0, bounds.width), height: actualGap))
                cursor += actualGap
            }
        }
        return .init(panes: panes, dividers: dividers)
    }

    static func resized(_ ratios: [Double], divider: Int, delta: CGFloat, available: CGFloat,
                        minimum: CGFloat = 120) -> [Double] {
        guard ratios.indices.contains(divider), ratios.indices.contains(divider + 1), available > 0, delta.isFinite else { return ratios }
        let sum = ratios[divider] + ratios[divider + 1]
        let lower = min(Double(max(0, minimum) / available), sum / 2)
        let first = min(max(ratios[divider] + Double(delta / available), lower), sum - lower)
        var result = ratios
        result[divider] = first
        result[divider + 1] = sum - first
        return result
    }
}
