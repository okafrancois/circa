import Foundation

public struct SplitGroupID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum BrowserSplitOrientation: String, Codable, Sendable { case horizontal, vertical }

public struct BrowserSplitGroup: Codable, Equatable, Sendable {
    public static let maximumPanes = 4
    public let id: SplitGroupID
    public internal(set) var tabIDs: [TabID]
    public internal(set) var orientation: BrowserSplitOrientation
    /// Positive fractions summing to one. No focused tab is shared: selection belongs to a window.
    public internal(set) var ratios: [Double]

    public init(id: SplitGroupID = SplitGroupID(), tabIDs: [TabID],
                orientation: BrowserSplitOrientation = .horizontal, ratios: [Double]? = nil) {
        self.id = id
        self.tabIDs = tabIDs
        self.orientation = orientation
        self.ratios = ratios ?? Array(repeating: 1 / Double(max(1, tabIDs.count)), count: tabIDs.count)
    }

    public var isValid: Bool {
        (2...Self.maximumPanes).contains(tabIDs.count) && Set(tabIDs).count == tabIDs.count
            && ratios.count == tabIDs.count && ratios.allSatisfy { $0.isFinite && $0 > 0 }
            && abs(ratios.reduce(0, +) - 1) < 0.000_001
    }
}

public struct BrowserOrganizationSplitItem: Equatable, Sendable {
    public let group: BrowserSplitGroup
    public let tabs: [BrowserOrganizationTabItem]
    public var activeTab: BrowserOrganizationTabItem? { tabs.first { $0.isSelected } }
}

public enum BrowserSplitError: Error, Equatable, Sendable {
    case invalidPaneCount, invalidRatios, nestedSplit, incompatibleSection, paneMissing, staleLayout
}
