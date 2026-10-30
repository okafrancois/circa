import CryptoKit
import Darwin
import Foundation

/// The digest is public binding data, never a key or a Keychain persistent reference.
protocol OrbitRecoveryRegistrationBindingProvider: OrbitRecoveryKeyProvider {
    func registrationBinding() throws -> Data
}

/// An immutable, nonsecret registration outside every restorable profile/state tree.
/// Filesystem ownership authenticates its initial publication. Registered recovery additionally
/// authenticates the exact record through the encrypted journal's intent AAD. As with recovery,
/// malicious concurrent writers with this user's authority are outside the threat model.
public final class OrbitRecoveryRootRegistration {
    public enum PublicationBoundary: Sendable { case written, durable, published }
    static let fileName = ".orbit-auth-root-registration"
    struct Record: Codable, Equatable {
        let version: Int
        let registration: UUID
        let product: String
        let service: String
        let owner: UInt32
        let rootDevice: UInt64
        let rootInode: UInt64
        let location: Data
        let fileDevice: UInt64
        let fileInode: UInt64
    }
    private let lease: OrbitRecoveryRootLock
    private let descriptor: Int32
    private let bytes: Data
    let record: Record

    private init(lease: OrbitRecoveryRootLock, product: OrbitNativeRecoveryKeyProvider.Product) throws {
        self.lease = lease
        descriptor = try lease.root.openFile(Self.fileName)
        do {
            let data = try lease.root.read(Self.fileName, limit: 4096)
            let decoded = try OrbitAuthenticationRecovery.decode(Record.self, data)
            bytes = data; record = decoded
        } catch { close(descriptor); throw error }
        try validate(product: product)
    }
    deinit { close(descriptor) }

    private static func strictRoot(_ lease: OrbitRecoveryRootLock) throws -> Data {
        try lease.validate()
        return try lease.root.registrationLocation()
    }
    func validate(product: OrbitNativeRecoveryKeyProvider.Product) throws {
        let location = try Self.strictRoot(lease)
        try lease.root.validateFile(Self.fileName, fd: descriptor)
        var file = stat()
        guard fstat(descriptor, &file) == 0,
              try RecoveryDirectory.registrationMetadata(descriptor),
              record.version == 1, record.product == product.rawValue,
              record.service == product.recoveryService, record.owner == getuid(),
              record.rootDevice == lease.root.device, record.rootInode == lease.root.inode,
              record.location == location, record.fileDevice == UInt64(truncatingIfNeeded: file.st_dev),
              record.fileInode == UInt64(file.st_ino),
              try lease.root.read(Self.fileName, limit: 4096) == bytes,
              try OrbitAuthenticationRecovery.encode(record) == bytes,
              try lease.root.info(Self.fileName + ".writing") == nil
        else { throw OrbitRecoveryFailure.invalidEvidence }
    }
    func binding(product: OrbitNativeRecoveryKeyProvider.Product) throws -> Data {
        try validate(product: product)
        return Data(SHA256.hash(data: bytes))
    }

    /// Early read-only admission, before directory preparation can normalize permissions.
    /// Final identity and lock admission still occurs at the startup seam.
    public static func preflightExistingRoot(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }; throw OrbitRecoveryFailure.unsafeFilesystem
        }
        let root = try RecoveryDirectory(url: url)
        if try hasEvidence(root) || root.info(fileName) != nil || root.info(fileName + ".writing") != nil {
            _ = try root.registrationLocation()
            // Refuse unsafe registration entries before legacy layout validation can report a
            // path or normalize metadata. Decoding/authority admission remains under locks.
            for name in [fileName, fileName + ".writing"] where try root.info(name) != nil {
                let file = try root.openFile(name); close(file)
            }
        }
    }
    static func hasEvidence(_ root: RecoveryDirectory) throws -> Bool {
        for name in [OrbitAuthenticationRecovery.marker, OrbitAuthenticationRecovery.marker + ".writing", OrbitAuthenticationRecovery.directory] {
            if try root.info(name) != nil { return true }
        }
        return false
    }
    static func rejectStructuralEvidence(_ root: RecoveryDirectory) throws {
        if try root.info("Import") != nil {
            let directory = try RecoveryDirectory(parent: root, name: "Import")
            guard !(try directory.names()).contains(where: {
                $0 == "arc-import-journal.json" || $0 == "arc-import-restore.json" || $0.hasPrefix(".restore-")
            }) else { throw OrbitRecoveryFailure.invalidEvidence }
        }
    }
    /// No public ordinary-start creation capability. This explicit preparation requires the
    /// exact existing synthetic marker, a private root and all existing offline locks.
    /// Interruptions retain .writing/final evidence; there is no repair or orphan cleanup.
    public static func prepareSynthetic(lease: OrbitRecoveryRootLock, product: OrbitNativeRecoveryKeyProvider.Product,
                                        failpoint: (PublicationBoundary) throws -> Void = { _ in }) throws -> OrbitRecoveryRootRegistration {
        let structural = try RecoveryImportLock(root: lease.root)
        return try withExtendedLifetime(structural) {
            let location = try strictRoot(lease)
            let root = lease.root
            guard try root.read(OrbitAuthenticationRecovery.syntheticMarker, limit: 64) == Data("orbit-auth-recovery-synthetic-v1\n".utf8),
                  try !hasEvidence(root), try root.info(fileName + ".writing") == nil
            else { throw OrbitRecoveryFailure.invalidEvidence }
            try rejectStructuralEvidence(root)
            if try root.info(fileName) != nil { return try Self(lease: lease, product: product) }
            let temporary = fileName + ".writing"
            let file = try root.openFile(temporary, create: true, exclusive: true)
            defer { close(file) }
            var info = stat()
            guard fstat(file, &info) == 0 else { throw OrbitRecoveryFailure.io }
            let record = Record(version: 1, registration: UUID(), product: product.rawValue,
                                service: product.recoveryService, owner: getuid(), rootDevice: root.device,
                                rootInode: root.inode, location: location,
                                fileDevice: UInt64(truncatingIfNeeded: info.st_dev), fileInode: UInt64(info.st_ino))
            try RecoveryDirectory.write(OrbitAuthenticationRecovery.encode(record), fd: file)
            try failpoint(.written)
            guard fsync(file) == 0, fcntl(file, F_FULLFSYNC) == 0 else { throw OrbitRecoveryFailure.io }
            try failpoint(.durable)
            _ = try strictRoot(lease); try root.validateFile(temporary, fd: file)
            guard try root.info(fileName) == nil,
                  renameatx_np(root.fd, temporary, root.fd, fileName, UInt32(RENAME_EXCL)) == 0 else { throw OrbitRecoveryFailure.io }
            try root.sync()
            try failpoint(.published)
            return try Self(lease: lease, product: product)
        }
    }
    // Called only with the structural lock held by registered startup/preparation.
    static func load(lease: OrbitRecoveryRootLock, product: OrbitNativeRecoveryKeyProvider.Product) throws -> OrbitRecoveryRootRegistration? {
        try lease.validate()
        guard try lease.root.info(fileName + ".writing") == nil else { throw OrbitRecoveryFailure.invalidEvidence }
        guard try lease.root.info(fileName) != nil else {
            guard try !hasEvidence(lease.root) else { throw OrbitRecoveryFailure.invalidEvidence }
            return nil
        }
        return try Self(lease: lease, product: product)
    }
    /// Explicit synthetic admission only; startup never receives this capability.
    public func syntheticKeyProvider(product: OrbitNativeRecoveryKeyProvider.Product,
                                     backend: any OrbitRecoverySecItemBoundary) throws -> any OrbitRecoveryKeyAdmissionProvider {
        try validate(product: product)
        guard try lease.root.read(OrbitAuthenticationRecovery.syntheticMarker, limit: 64) == Data("orbit-auth-recovery-synthetic-v1\n".utf8) else { throw OrbitRecoveryFailure.invalidEvidence }
        return RegisteredRecoveryAdmission(registration: self, product: product, backend: backend)
    }
}

extension OrbitNativeRecoveryKeyProvider.Product {
    var recoveryService: String {
        self == .daily ? ProductIdentity.keychainAccount + " Authentication Recovery v1" : "Orbit Live Authentication Recovery v1"
    }
}

/// Exposes only load, even though the internal adapter can also explicitly prepare keys.
private class RegisteredRecoveryLoader: OrbitRecoveryRegistrationBindingProvider {
    let registration: OrbitRecoveryRootRegistration
    let product: OrbitNativeRecoveryKeyProvider.Product
    let native: OrbitNativeRecoveryKeyProvider
    init(registration: OrbitRecoveryRootRegistration, product: OrbitNativeRecoveryKeyProvider.Product,
         backend: any OrbitRecoverySecItemBoundary) {
        self.registration = registration; self.product = product
        native = OrbitNativeRecoveryKeyProvider(product: product, registration: registration.record.registration, backend: backend)
    }
    func registrationBinding() throws -> Data { try registration.binding(product: product) }
    func loadRecoveryKey(transaction: UUID) throws -> SymmetricKey {
        _ = try registrationBinding()
        return try native.loadRecoveryKey(transaction: transaction)
    }
}
private final class RegisteredRecoveryAdmission: RegisteredRecoveryLoader, OrbitRecoveryKeyAdmissionProvider {
    func prepareRecoveryKey(transaction: UUID) throws {
        _ = try registrationBinding(); try native.prepareRecoveryKey(transaction: transaction)
    }
    func retainRecoveryKeyForEvidence(transaction: UUID) throws {
        _ = try registrationBinding(); try native.retainRecoveryKeyForEvidence(transaction: transaction)
    }
}

extension OrbitAuthenticationStartupGate {
    /// Product seam. Backend factory is lazy and mandatory: mock composition cannot silently
    /// fall back to Security. The system adapter's constructor itself is passive.
    public static func runRegistered<T>(lease: OrbitRecoveryRootLock, product: OrbitNativeRecoveryKeyProvider.Product,
                                        backend: () throws -> any OrbitRecoverySecItemBoundary,
                                        now: Int64 = Int64(Date().timeIntervalSince1970),
                                        beforeStructuralRecovery: () throws -> Void = {},
                                        runtimeStart: () throws -> T) throws -> T {
        try lease.validate()
        let structural = try RecoveryImportLock(root: lease.root)
        let registration = try OrbitRecoveryRootRegistration.load(lease: lease, product: product)
        let provider: (any OrbitRecoveryKeyProvider)?
        if let registration, try OrbitRecoveryRootRegistration.hasEvidence(lease.root) {
            provider = RegisteredRecoveryLoader(registration: registration, product: product, backend: try backend())
        } else { provider = nil }
        let recovery = try OrbitAuthenticationRecovery.prepareBeforeRuntime(lease: lease, provider: provider, now: now,
                                                                          heldImportLock: structural)
        let location = try lease.root.sessionLocation()
        // Finish interrupted structural restoration while the same exclusive root
        // lock is held, before BrowserEnvironment would otherwise reopen it.
        try beforeStructuralRecovery()
        try ArcImportBackups.recoverInterruptedRestore(at: location, holdingLock: true)
        if let registration { try registration.validate(product: product) }
        try structural.allowSessionReaders()
        try validateRegisteredRuntime(lease: lease, product: product, registration: registration,
                                      recovery: recovery, location: location, now: now)
        // Instance and recovery locks stay exclusive. The root directory stays
        // shared, permitting the session's own reader while excluding offline writers.
        return try withExtendedLifetime((lease, structural, registration, recovery)) { try runtimeStart() }
    }

    static func validateRegisteredRuntime(lease: OrbitRecoveryRootLock, product: OrbitNativeRecoveryKeyProvider.Product,
                                          registration: OrbitRecoveryRootRegistration?, recovery: OrbitAuthenticationRecovery?,
                                          location: ArcImportDataLocation, now: Int64) throws {
        try lease.validate()
        if let registration { try registration.validate(product: product) }
        else {
            guard try lease.root.info(OrbitRecoveryRootRegistration.fileName) == nil,
                  try lease.root.info(OrbitRecoveryRootRegistration.fileName + ".writing") == nil
            else { throw OrbitRecoveryFailure.invalidEvidence }
        }
        if let recovery { try recovery.validateRuntimeAdmission(now: now) }
        else { guard try !OrbitRecoveryRootRegistration.hasEvidence(lease.root) else { throw OrbitRecoveryFailure.invalidEvidence } }
        // A writer may have acquired the root during flock's mode conversion.
        // Never mutate under the shared lock or admit a newly interrupted restore.
        guard !ArcImportBackups.hasInterruptedRestore(at: location) else { throw ArcImportError.restoreInterrupted }
    }
}
