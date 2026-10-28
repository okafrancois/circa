import Foundation

/// Engines may expose site-data operations independently of surface lifetime. Data records
/// can cover a registrable domain, so UI must disclose the actual scope before deletion.
public struct BrowserSiteDataSummary: Sendable, Equatable {
    public let domains: [String]
    public let recordCount: Int
    public let cookieCount: Int?
    public let hasStorage: Bool?
    public let isAvailable: Bool
    public init(domains: [String], recordCount: Int, cookieCount: Int? = nil,
                hasStorage: Bool? = nil, isAvailable: Bool = true) {
        self.domains = domains.sorted()
        self.recordCount = recordCount
        self.cookieCount = cookieCount
        self.hasStorage = hasStorage
        self.isAvailable = isAvailable
    }
}

public enum BrowserSiteDataError: Error { case scopeChanged, removalIncomplete }

@MainActor
public protocol BrowserSitePermissionAvailability: AnyObject {
    var supportedSitePermissions: Set<BrowserSitePermission> { get }
    /// Stops an existing grant on live documents. Nil resets camera and microphone together.
    func revokeSitePermission(_ permission: BrowserSitePermission?, origin: BrowserSiteOrigin, profileID: ProfileID) async
    /// Reconciles the shell's stored choice with an engine that persists its own grants.
    func setSitePermission(_ setting: BrowserSitePermissionSetting, permission: BrowserSitePermission,
                           origin: BrowserSiteOrigin, profileID: ProfileID) async
}

extension BrowserSitePermissionAvailability {
    public func setSitePermission(_ setting: BrowserSitePermissionSetting, permission: BrowserSitePermission,
                                  origin: BrowserSiteOrigin, profileID: ProfileID) async {
        if setting != .allow { await revokeSitePermission(permission, origin: origin, profileID: profileID) }
    }
}

/// Optional service until the coordinated BrowserEngine contract revision. No emulation.
@MainActor
public protocol BrowserSiteOriginDataAccess: AnyObject {
    func siteData(origin: BrowserSiteOrigin, profileID: ProfileID) async -> BrowserSiteDataSummary
    func clearSiteData(origin: BrowserSiteOrigin, profileID: ProfileID, expectedDomains: [String]) async throws
}

/// Engines advertise profile-wide erasure separately from their origin-scoped operations.
@MainActor
public protocol BrowserSiteDataAccess: BrowserSiteOriginDataAccess {
    func clearSiteData(profileID: ProfileID) async throws
}
