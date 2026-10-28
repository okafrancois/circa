import CommonCrypto
import CryptoKit
import Foundation

/// Code-only failures. Never attach source data, provider errors or paths.
public enum ArcAuthenticationError: Error, Equatable, Sendable {
    case unsupportedSchema, unsupportedCiphertext, unsupportedPartition
    case unsupportedSameSite, unsupportedSourceMetadata, reauthenticationRequired
    case syntheticOnly, sizeLimit, ambiguousValue, invalidTime, skippedExpired
    case invalidCookie, invalidPrefix, insecureSameSiteNone, invalidValue
    case sourceKeyUnavailable, decryptionFailed, hostHashMismatch, secretDestroyed
    case invalidMapping, invalidTransition, realMutationDisabled
}

/// Deliberately not Codable. Default descriptions and mirrors must not expose secrets/hosts.
public protocol ArcAuthenticationPrivateValue: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {}
extension ArcAuthenticationPrivateValue {
    public var description: String { "<authentication-private>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}

/// In-memory, typed synthetic SQL-v24 row; not a SQLite reader or personal import entry point.
/// Booleans must already have been strictly decoded from SQL 0/1 by a future reader.
public struct ArcSyntheticCookieRow: ArcAuthenticationPrivateValue {
    public var schemaVersion = 24
    public var compatibleVersion = 24
    public var host: String
    public var name: String
    public var path = "/"
    public var plaintextValue: [UInt8] = []
    public var encryptedValue: [UInt8]
    public var partitionSite = ""
    public var crossSiteAncestor = false
    public var deviceBound = false
    public var secure = true
    public var httpOnly = true
    public var sameSite = 2
    public var priority = 1
    public var sourceScheme = 2
    public var sourcePort = 443
    public var sourceType = 1
    public var creation: Int64
    public var lastAccess: Int64
    public var lastUpdate: Int64
    public var expiry: Int64
    public var hasExpiry = true
    public var persistent = true

    public init(host: String, name: String, encryptedValue: [UInt8], creation: Int64,
                lastAccess: Int64, lastUpdate: Int64, expiry: Int64) {
        self.host = host; self.name = name; self.encryptedValue = encryptedValue
        self.creation = creation; self.lastAccess = lastAccess; self.lastUpdate = lastUpdate; self.expiry = expiry
    }
}

public enum ArcCookieSameSite: Int, Sendable {
    case unspecified = -1, none = 0, lax = 1, strict = 2
    /// SQL and public CEF are different enums; never cast the SQL integer.
    public var cefValue: Int32 {
        switch self {
        case .unspecified: 0
        case .none: 1
        case .lax: 2
        case .strict: 3
        }
    }
}

public enum ArcCookieNormalization: Sendable, Hashable {
    case creationRegenerated, accessRegenerated, updateRegenerated, sourceTypeToOther, expiryMayBeClamped
}

/// Explicit source provider for invented fixtures only. No Keychain API, default password,
/// empty-key fallback, target-provider hook or filesystem input. Single-owner, non-Sendable.
public final class ArcSyntheticSourceSecret: ArcAuthenticationPrivateValue {
    private var password: [UInt8]
    public private(set) var accessCount = 0

    public init(password: [UInt8]) { self.password = password }
    public func destroy() { Self.wipe(&password) }
    deinit { Self.wipe(&password) }

    fileprivate func deriveKey() throws -> [UInt8] {
        guard !password.isEmpty, password.count <= 1024 else { throw ArcAuthenticationError.sourceKeyUnavailable }
        accessCount += 1
        return Array(try ArcChromiumCookieCipher.deriveKey(password: Data(password)))
    }

    fileprivate static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            if let address = buffer.baseAddress { memset_s(address, buffer.count, 0, buffer.count) }
        }
        bytes.removeAll(keepingCapacity: false)
    }
}

/// Privately retained admitted source fields, before installation. Not a claim of inventory,
/// target canonical identity, durability, or exact preservation of regenerated metadata.
public final class ArcPreparedSyntheticCookie: ArcAuthenticationPrivateValue {
    public let host: String
    public let hostOnly: Bool
    public let name: String
    public let path: String
    public let secure: Bool
    public let httpOnly: Bool
    public let sameSite: ArcCookieSameSite
    public let priority: Int
    public let sourceScheme: Int
    public let sourcePort: Int
    public let sourceType: Int
    public let creation: Int64
    public let lastAccess: Int64
    public let lastUpdate: Int64
    public let expiry: Int64?
    /// Public CEF CreateSanitizedCookie supplies CookieSourceType::kOther (3).
    public let normalizedSourceType = 3
    public let normalization: Set<ArcCookieNormalization>
    private var value: [UInt8]
    private var destroyed = false

    fileprivate init(row: ArcSyntheticCookieRow, sameSite: ArcCookieSameSite, value: [UInt8]) {
        host = row.host; hostOnly = !row.host.hasPrefix("."); name = row.name; path = row.path
        secure = row.secure; httpOnly = row.httpOnly; self.sameSite = sameSite; priority = row.priority
        sourceScheme = row.sourceScheme; sourcePort = row.sourcePort; sourceType = row.sourceType
        creation = row.creation; lastAccess = row.lastAccess; lastUpdate = row.lastUpdate
        expiry = row.hasExpiry ? row.expiry : nil; self.value = value
        var normalization: Set<ArcCookieNormalization> = [.creationRegenerated, .accessRegenerated, .updateRegenerated]
        if row.sourceType != 3 { normalization.insert(.sourceTypeToOther) }
        if row.hasExpiry { normalization.insert(.expiryMayBeClamped) }
        self.normalization = normalization
    }

    /// The closure must not retain/copy the bytes into logs, Codable models or generic events.
    public func withValue<T>(_ body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
        guard !destroyed else { throw ArcAuthenticationError.secretDestroyed }
        return try value.withUnsafeBytes(body)
    }

    public func destroy() { ArcSyntheticSourceSecret.wipe(&value); destroyed = true }
    deinit { ArcSyntheticSourceSecret.wipe(&value) }
}

public enum ArcChromiumSecretDecoder {
    /// Bounded, in-memory synthetic adapter only. No call site in product import or startup.
    /// This first subset admits unpartitioned ASCII `.test` DNS hosts at HTTPS/443 only.
    /// Secret buffers are wiped best effort; Swift caller copies cannot be guaranteed erased.
    public static func decodeSyntheticV24(_ row: ArcSyntheticCookieRow, now: Int64,
                                         source: ArcSyntheticSourceSecret) throws -> ArcPreparedSyntheticCookie {
        guard row.schemaVersion == 24, row.compatibleVersion == 24 else { throw ArcAuthenticationError.unsupportedSchema }
        guard row.host.utf8.count <= 254, row.name.utf8.count <= 1024, row.path.utf8.count <= 1024,
              row.plaintextValue.count <= 4096, row.encryptedValue.count <= 8192,
              row.partitionSite.utf8.count <= 2048 else { throw ArcAuthenticationError.sizeLimit }
        guard row.partitionSite.isEmpty, !row.crossSiteAncestor else { throw ArcAuthenticationError.unsupportedPartition }
        guard !row.deviceBound else { throw ArcAuthenticationError.reauthenticationRequired }
        guard row.sourceScheme == 2, row.sourcePort == 443, (1...3).contains(row.sourceType) else {
            throw ArcAuthenticationError.unsupportedSourceMetadata
        }
        guard let sameSite = ArcCookieSameSite(rawValue: row.sameSite) else { throw ArcAuthenticationError.unsupportedSameSite }
        guard (0...2).contains(row.priority) else { throw ArcAuthenticationError.invalidCookie }
        try validateIdentity(row)
        guard sameSite != .none || row.secure else { throw ArcAuthenticationError.insecureSameSiteNone }
        try validateTime(row, now: now)
        guard row.plaintextValue.isEmpty || row.encryptedValue.isEmpty else { throw ArcAuthenticationError.ambiguousValue }

        var value: [UInt8]
        if row.encryptedValue.isEmpty {
            value = row.plaintextValue
        } else {
            let cipher = row.encryptedValue
            guard cipher.starts(with: Array("v10".utf8)), cipher.count >= 19, (cipher.count - 3) % 16 == 0 else {
                throw ArcAuthenticationError.unsupportedCiphertext
            }
            var key = try source.deriveKey()
            defer { ArcSyntheticSourceSecret.wipe(&key) }
            var clear = try decrypt(cipher, key: key)
            defer { ArcSyntheticSourceSecret.wipe(&clear) }
            // Compare the *stored* host bytes, including its dot, before decoding any UTF-8.
            let expected = Array(SHA256.hash(data: Data(row.host.utf8)))
            guard clear.count >= expected.count else { throw ArcAuthenticationError.hostHashMismatch }
            var difference: UInt8 = 0
            for index in expected.indices { difference |= clear[index] ^ expected[index] }
            guard difference == 0 else { throw ArcAuthenticationError.hostHashMismatch }
            value = Array(clear.dropFirst(expected.count))
        }
        defer { ArcSyntheticSourceSecret.wipe(&value) }
        guard value.count + row.name.utf8.count <= 4096,
              String(bytes: value, encoding: .utf8) != nil,
              value.allSatisfy({ $0 == 0x21 || (0x23...0x2b).contains($0) || (0x2d...0x3a).contains($0)
                  || (0x3c...0x5b).contains($0) || (0x5d...0x7e).contains($0) }) else {
            throw ArcAuthenticationError.invalidValue
        }
        return ArcPreparedSyntheticCookie(row: row, sameSite: sameSite, value: value)
    }

    private static func validateIdentity(_ row: ArcSyntheticCookieRow) throws {
        let host = row.host.hasPrefix(".") ? String(row.host.dropFirst()) : row.host
        guard host.hasSuffix(".test") else { throw ArcAuthenticationError.syntheticOnly }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }), BrowserPublicSuffixList.shared.registrableDomain(of: host) != nil else {
            throw ArcAuthenticationError.invalidCookie
        }
        let separators = Set(Array("()<>@,;:\\\"/[]?={} \t".utf8))
        let pathCharacters = Set(Array("!$&'()*+,-./0123456789:=@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~".utf8))
        guard !row.name.isEmpty, row.name.utf8.allSatisfy({ (33...126).contains($0) && !separators.contains($0) }),
              row.path.hasPrefix("/"), !row.path.hasPrefix("//"), row.path.utf8.allSatisfy({ pathCharacters.contains($0) }),
              !row.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw ArcAuthenticationError.invalidCookie
        }
        // Chromium cookie_util::GetCookiePrefix compares ASCII case insensitively. The name
        // itself is retained unchanged; only the policy classification uses lowercase.
        let prefixName = row.name.lowercased()
        if prefixName.hasPrefix("__secure-"), !row.secure { throw ArcAuthenticationError.invalidPrefix }
        if prefixName.hasPrefix("__host-"), (!row.secure || row.host.hasPrefix(".") || row.path != "/") {
            throw ArcAuthenticationError.invalidPrefix
        }
        if prefixName.hasPrefix("__http-") || prefixName.hasPrefix("__host-http-"), (!row.secure || !row.httpOnly) {
            throw ArcAuthenticationError.invalidPrefix
        }
    }

    private static func validateTime(_ row: ArcSyntheticCookieRow, now: Int64) throws {
        // Integer microseconds since 1601; reject overflow/sentinels beyond year 9999.
        let maximum: Int64 = 265_046_774_399_999_999
        guard now > 0, now <= maximum,
              [row.creation, row.lastAccess, row.lastUpdate, row.expiry].allSatisfy({ $0 >= 0 && $0 <= maximum }),
              row.hasExpiry == row.persistent, row.hasExpiry || row.expiry == 0 else {
            throw ArcAuthenticationError.invalidTime
        }
        if row.hasExpiry, row.expiry <= now { throw ArcAuthenticationError.skippedExpired }
    }

    private static func decrypt(_ cipher: [UInt8], key: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: cipher.count - 3)
        let capacity = output.count
        let iv = [UInt8](repeating: 32, count: 16)
        var size = 0
        let status = key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in cipher.withUnsafeBytes { cipher in
            output.withUnsafeMutableBytes { output in
                // Check every PKCS#7 byte ourselves; successful library unpadding alone must
                // not admit a malformed tail (including one with a plausible last byte).
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                    key.baseAddress, 16, iv.baseAddress, cipher.baseAddress!.advanced(by: 3), cipher.count - 3,
                    output.baseAddress, capacity, &size)
            }
        } } }
        guard status == kCCSuccess else { ArcSyntheticSourceSecret.wipe(&output); throw ArcAuthenticationError.decryptionFailed }
        output.removeLast(output.count - size)
        guard let padding = output.last, (1...16).contains(padding), output.count >= Int(padding),
              output.suffix(Int(padding)).allSatisfy({ $0 == padding }) else {
            ArcSyntheticSourceSecret.wipe(&output)
            throw ArcAuthenticationError.decryptionFailed
        }
        // Clear padding before releasing its storage. The remaining native buffer is wiped
        // by the caller after host binding and bounded value admission.
        for index in (output.count - Int(padding))..<output.count { output[index] = 0 }
        output.removeLast(Int(padding))
        return output
    }
}
