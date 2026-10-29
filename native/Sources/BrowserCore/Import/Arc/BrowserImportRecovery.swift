import CryptoKit
import Foundation

/// Durable, source-independent undo for the fresh-profile import lane. Published before any
/// target mutation; the original files remain available even if ordinary restoration cannot copy.
public final class BrowserImportRecovery {
    public enum Choice: String, Codable, Sendable { case restore, continueWithoutImport }
    enum Phase: String, Codable { case mutating, runtimeReady, recovering, complete }
    private struct Document: Codable {
        var phase: Phase = .mutating
        var authentication: Bool
        var profiles: [UUID]
        var files: [String: String]
        var absent: [String]
        var choice: Choice?
        var usedFallback = false
    }
    private static let name = "ImportRecovery"
    private static let paths = ["session.json", "Import/arc-import-ledger.json", "Import/space-appearance.json",
                                "Import/arc-import-journal.json", "Chromium/Local State"]
    private let root: OrbitSecureDirectory
    private let directory: OrbitSecureDirectory
    private var document: Document
    public var needsRecovery: Bool { document.phase == .mutating || document.phase == .recovering }
    var isAuthentication: Bool { document.authentication }
    private init(root: OrbitSecureDirectory, directory: OrbitSecureDirectory, document: Document) {
        self.root = root; self.directory = directory; self.document = document
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func open(at dataRoot: URL) throws -> BrowserImportRecovery? {
        let root = try OrbitSecureDirectory.open(dataRoot, create: false)
        guard try root.checkedKind(name) != nil else { return nil }
        let directory = try root.directory(name, create: false)
        // Unpublished staging has not admitted a mutation.
        guard try directory.checkedKind("state.json") != nil else { return nil }
        guard let data = directory.read("state.json") else { throw ArcImportError.backupInvalid }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard Set(document.files.keys).union(document.absent) == Set(paths),
              Set(document.files.keys).isDisjoint(with: document.absent) else { throw ArcImportError.backupInvalid }
        return Self(root: root, directory: directory, document: document)
    }
    /// Only fresh, non-adopted profiles enter this lane. Existing-profile reimports and the
    /// legacy adapter retain their established history backup and restoration semantics.
    static func begin(at location: ArcImportDataLocation, profiles: [UUID], authentication: Bool, originalFiles: [String: Data]? = nil) throws -> BrowserImportRecovery {
        if let existing = try open(at: location.dataDirectory) {
            guard existing.isAuthentication, !authentication, existing.document.phase == .mutating,
                  existing.document.profiles == profiles else { throw ArcImportError.importInProgress }
            return existing
        }
        let root = try OrbitSecureDirectory.open(location.dataDirectory, create: false)
        if try root.checkedKind(name) != nil {
            let abandoned = try root.directory("ImportRecoveryHistory", create: true)
            try root.rename(name, to: abandoned, UUID().uuidString)
        }
        let directory = try root.directory(name, create: true)
        let originals = try directory.directory("Original", create: true)
        var files: [String: String] = [:], absent: [String] = []
        for path in paths {
            let url = root.url.appendingPathComponent(path)
            if originalFiles?[path] != nil || (originalFiles == nil && ArcImportFiles.exists(url)) {
                guard let bytes = originalFiles?[path] ?? ArcImportFiles.readData(url) else { throw ArcImportError.backupInvalid }
                let (parent, leaf) = try ArcImportRestore.parent(path, in: originals, create: true)
                try parent.write(bytes, to: leaf)
                files[path] = digest(bytes)
            } else { absent.append(path) }
        }
        let recovery = Self(root: root, directory: directory,
                            document: Document(authentication: authentication, profiles: profiles, files: files, absent: absent))
        try recovery.save()
        return recovery
    }
    private func save() throws { try directory.write(JSONEncoder().encode(document), to: "state.json") }
    func runtimeReady() throws { document.phase = .runtimeReady; try save() }
    func runtimeApplying() throws { document.phase = .mutating; try save() }
    func complete() throws {
        document.phase = .complete; try save()
        try archive()
    }
    private func archive() throws {
        let history = try root.directory("ImportRecoveryHistory", create: true)
        try root.rename(Self.name, to: history, UUID().uuidString)
    }
    /// Called while the startup gate owns the exclusive directory lock, before CEF or session
    /// readers. Both choices reject the incomplete import; the selected intent is retained.
    /// Imported trees and replaced files are quarantined, never deleted.
    @discardableResult
    public func recover(_ choice: Choice, holdingLock: Bool = false, quarantineAuthentication: Bool = true,
                        checkpoint: (String) throws -> Void = { _ in },
                        copyOriginal: ((Data, URL) throws -> Void)? = nil) throws -> Bool {
        let lock = holdingLock ? nil : try OrbitDataDirectoryLock.acquire(root.url, exclusive: true)
        defer { lock?.release() }
        document.phase = .recovering; document.choice = choice; try save()
        try checkpoint("recovery-journal")
        let discarded = try directory.directory("Quarantine", create: true)
        func park(_ path: String) throws {
            guard try ArcImportRestore.exists(path, in: root) else { return }
            let (source, name) = try ArcImportRestore.parent(path, in: root, create: false)
            let (target, leaf) = try ArcImportRestore.parent(path, in: discarded, create: true)
            // A prior attempt already retained the imported version. Retain retries separately.
            let destination = target.exists(leaf) ? leaf + "." + UUID().uuidString : leaf
            try source.rename(name, to: target, destination)
        }
        for id in document.profiles {
            for path in ["Chromium/profile-" + id.uuidString.lowercased(), "History/" + id.uuidString] {
                try park(path); try checkpoint("recovery-profile:" + path); try checkpoint("recovery-profile")
            }
        }
        let originals = try directory.directory("Original", create: false)
        for path in Self.paths {
            let url = root.url.appendingPathComponent(path)
            if let expected = document.files[path] {
                if let current = ArcImportFiles.readData(url), Self.digest(current) == expected { continue }
                let (source, name) = try ArcImportRestore.parent(path, in: originals, create: false)
                guard let bytes = source.read(name), Self.digest(bytes) == expected else { throw ArcImportError.backupInvalid }
                try park(path)
                let (parent, leaf) = try ArcImportRestore.parent(path, in: root, create: true)
                do {
                    if let copyOriginal { try copyOriginal(bytes, url) }
                    else { try parent.write(bytes, to: leaf) }
                } catch {
                    // No extra disk space is needed to restore the retained original by rename.
                    // A retry recognizes it by digest if interrupted after this move.
                    try source.rename(name, to: parent, leaf)
                    document.usedFallback = true; try save()
                }
            } else { try park(path) }
            try checkpoint("recovery-file:" + path)
        }
        if document.authentication && quarantineAuthentication { try park("AuthenticationImport") }
        try checkpoint("recovery-authentication")
        document.phase = .complete; try save()
        try checkpoint("recovery-complete")
        try archive()
        return document.usedFallback
    }
    /// Remove a terminal marker left by a crash between completion and archival.
    public func finishCompleted() throws {
        if document.phase == .complete { try archive() }
    }
}
