import Foundation

public enum BrowserImportCapability: String, Codable, Sendable {
    case supported, empty, needsExport, unsupportedVersion, failed
}

public struct BrowserImportDescriptor: Sendable, Equatable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let supportPath: String
}

/// An installation registration is explicit: a copied source reuses its UUID only when the caller
/// intentionally identifies it as the same installation. No source path is persisted in the ledger.
public struct BrowserImportRegistration: Sendable, Equatable {
    public let sourceID: String
    public let installationID: UUID
    public init(sourceID: String, installationID: UUID) {
        self.sourceID = sourceID
        self.installationID = installationID
    }
    public var namespace: String { "v2:" + Data(sourceID.utf8).base64EncodedString() + ":" + installationID.uuidString }
    public func profileKey(_ directory: String) -> String { namespace + ":" + Data(directory.utf8).base64EncodedString() }
}

public struct BrowserImportSourceProfile: Sendable, Equatable {
    public let directory: String
    public let name: String
    public init(directory: String, name: String) { self.directory = directory; self.name = name }
}

public protocol BrowserImportHistoryReader: AnyObject {
    var counts: ArcHistoryScanCounts { get }
    var totalVisits: Int { get }
    func nextChunk(size: Int) throws -> [BrowserHistoryVisit]?
}
extension ArcChromiumHistoryReader: BrowserImportHistoryReader {}

public struct BrowserImportSourcePlan: Sendable {
    public var plan: BrowserImportPlan
    public var formatVersion: Int?
    public var diagnostics = ArcSidebarDiagnostics()
    public var archiveUnreadable = false
    public var capabilities: [String: BrowserImportCapability]?
}

public protocol BrowserImportSourceAdapter: Sendable {
    var descriptor: BrowserImportDescriptor { get }
    func discoverProfiles(metadata: Data) throws -> [BrowserImportSourceProfile]
    func snapshot(source: URL, parent: URL, probe: any ArcRunningProbe,
                  diskSpace: any OrbitDiskSpaceProbe) throws -> ArcSourceSnapshot
    func makePlan(snapshot: ArcSourceSnapshot, ledger: BrowserImportLedger,
                  defaultProfile: ProfileID?, importedAt: Date) throws -> BrowserImportSourcePlan
    func historyReader(file: URL, directory: String) throws -> any BrowserImportHistoryReader
}

public struct ArcBrowserImportAdapter: BrowserImportSourceAdapter {
    public var options: ArcImportOptions
    public init(options: ArcImportOptions = .init()) { self.options = options }
    public let descriptor = BrowserImportDescriptor(id: "arc", name: "Arc", bundleID: "company.thebrowser.Browser", supportPath: "Arc")
    public func discoverProfiles(metadata: Data) throws -> [BrowserImportSourceProfile] {
        try ChromiumBrowserImportAdapter.profiles(metadata)
    }
    public func snapshot(source: URL, parent: URL, probe: any ArcRunningProbe,
                         diskSpace: any OrbitDiskSpaceProbe) throws -> ArcSourceSnapshot {
        try ArcSourceSnapshot.capture(source: source, includeHistory: options.includeHistory, parent: parent, probe: probe, diskSpace: diskSpace)
    }
    public func makePlan(snapshot: ArcSourceSnapshot, ledger: BrowserImportLedger,
                         defaultProfile: ProfileID?, importedAt: Date) throws -> BrowserImportSourcePlan {
        let sidebar = try ArcJSON.parse(Data(contentsOf: snapshot.sidebar))
        let archive = snapshot.archive.flatMap { try? ArcJSON.parse(Data(contentsOf: $0), allowingArray: true) }
        let localState = snapshot.localState.flatMap { try? ArcJSON.parse(Data(contentsOf: $0)) }
        let graph = try ArcSidebarParser.parse(sidebar: sidebar, archive: archive, localState: localState,
                                              legacyProfileDirectories: options.legacyProfileDirectories)
        return BrowserImportSourcePlan(plan: ArcImportMapper.plan(graph, options: options, defaultProfileTarget: defaultProfile,
            importedAt: importedAt, profileTargets: ledger.profileTargets), formatVersion: graph.formatVersion,
            diagnostics: graph.diagnostics, archiveUnreadable: snapshot.archive != nil && archive == nil)
    }
    public func historyReader(file: URL, directory: String) throws -> any BrowserImportHistoryReader {
        try ArcChromiumHistoryReader(snapshotFile: file, directory: directory, identity: .init(namespace: options.namespace))
    }
}

/// The app supplies LaunchServices results; tests inject inventories without querying installed apps.
public enum ChromiumImportRegistry {
    public static let descriptors: [BrowserImportDescriptor] = [
        .init(id: "chrome", name: "Chrome", bundleID: "com.google.Chrome", supportPath: "Google/Chrome"),
        .init(id: "brave", name: "Brave", bundleID: "com.brave.Browser", supportPath: "BraveSoftware/Brave-Browser"),
        .init(id: "edge", name: "Edge", bundleID: "com.microsoft.edgemac", supportPath: "Microsoft Edge"),
        .init(id: "vivaldi", name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", supportPath: "Vivaldi"),
        .init(id: "opera", name: "Opera", bundleID: "com.operasoftware.Opera", supportPath: "com.operasoftware.Opera"),
        .init(id: "dia", name: "Dia", bundleID: "company.thebrowser.dia", supportPath: "Dia/User Data"),
        .init(id: "chromium", name: "Chromium", bundleID: "org.chromium.Chromium", supportPath: "Chromium")
    ]
    public static func installed(inventory: (String) -> [URL]) -> [BrowserImportDescriptor] {
        descriptors.filter { !inventory($0.bundleID).isEmpty }
    }
}

/// Compatibility names retain v1 storage filenames and restore semantics for existing imports.
public typealias BrowserImportSnapshot = ArcSourceSnapshot
public typealias BrowserImportTarget = ArcImportTarget
public typealias BrowserImportPreparation = ArcImportPreparation

public struct BrowserImportRunningProbe: ArcRunningProbe {
    private let running: @Sendable () -> Bool
    public init(running: @escaping @Sendable () -> Bool) { self.running = running }
    public func isArcRunning(sourceRoot: URL) -> Bool {
        running() || ArcSystemRunningProbe.singletonLockIsLive(sourceRoot.appendingPathComponent("SingletonLock"))
    }
}
