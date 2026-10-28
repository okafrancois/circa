import Foundation

public enum BrowserPageZoomError: Error, Equatable, Sendable {
    case invalidBounds
    case invalidDefaultFactor
    case defaultFactorOutOfBounds
    case invalidFactor
    case factorOutOfBounds
    case invalidLevel
}

/// Pure page-zoom policy; engine application and site/profile persistence belong to the adapter.
/// Reference: Chromium d0c02bfad08ec92a6ffcf989e53cd995e6381a4c,
/// third_party/blink/common/page/page_zoom.cc and components/zoom/page_zoom.cc.
/// Chromium navigates and compares presets in zoom-level space (log base 1.2).
public struct BrowserPageZoom: Sendable {
    public static let presetFactors: [Double] = [
        0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75, 0.8, 0.9, 1,
        1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5
    ]
    public static let epsilon = 0.001

    public let defaultFactor: Double
    public let minimumFactor: Double
    public let maximumFactor: Double
    public let factors: [Double]
    public var resetFactor: Double { defaultFactor }

    private let levels: [Double]

    /// Custom finite positive bounds include their endpoints as available steps. A custom default
    /// is inserted unless its zoom level is already within epsilon of an available step.
    public init(
        defaultFactor: Double = 1, minimumFactor: Double = 0.25, maximumFactor: Double = 5
    ) throws {
        guard minimumFactor.isFinite, maximumFactor.isFinite,
              minimumFactor > 0, minimumFactor <= maximumFactor else {
            throw BrowserPageZoomError.invalidBounds
        }
        guard defaultFactor.isFinite, defaultFactor > 0 else {
            throw BrowserPageZoomError.invalidDefaultFactor
        }
        guard (minimumFactor...maximumFactor).contains(defaultFactor) else {
            throw BrowserPageZoomError.defaultFactorOutOfBounds
        }
        self.defaultFactor = defaultFactor
        self.minimumFactor = minimumFactor
        self.maximumFactor = maximumFactor
        var steps = Self.presetFactors.filter { (minimumFactor...maximumFactor).contains($0) }
        for endpoint in [minimumFactor, maximumFactor] where !steps.contains(endpoint) {
            steps.append(endpoint)
        }
        let defaultLevel = try Self.level(forFactor: defaultFactor)
        if !steps.contains(where: { abs(Self.uncheckedLevel($0) - defaultLevel) <= Self.epsilon }) {
            steps.append(defaultFactor)
        }
        factors = steps.sorted()
        levels = factors.map(Self.uncheckedLevel)
    }

    /// At a limit, or within epsilon of the final available step, the current factor is unchanged.
    public func nextFactor(after factor: Double) throws -> Double {
        let current = try validatedLevel(factor)
        guard let index = levels.firstIndex(where: { $0 > current && abs($0 - current) > Self.epsilon }) else {
            return factor
        }
        return factors[index]
    }

    public func previousFactor(before factor: Double) throws -> Double {
        let current = try validatedLevel(factor)
        guard let index = levels.lastIndex(where: { $0 < current && abs($0 - current) > Self.epsilon }) else {
            return factor
        }
        return factors[index]
    }

    public static func level(forFactor factor: Double) throws -> Double {
        guard factor.isFinite, factor > 0 else { throw BrowserPageZoomError.invalidFactor }
        return uncheckedLevel(factor)
    }

    public static func factor(forLevel level: Double) throws -> Double {
        guard level.isFinite else { throw BrowserPageZoomError.invalidLevel }
        let factor = pow(1.2, level)
        guard factor.isFinite, factor > 0 else { throw BrowserPageZoomError.invalidLevel }
        return factor
    }

    private static func uncheckedLevel(_ factor: Double) -> Double { log(factor) / log(1.2) }

    private func validatedLevel(_ factor: Double) throws -> Double {
        let level = try Self.level(forFactor: factor)
        guard (minimumFactor...maximumFactor).contains(factor) else {
            throw BrowserPageZoomError.factorOutOfBounds
        }
        return level
    }
}
