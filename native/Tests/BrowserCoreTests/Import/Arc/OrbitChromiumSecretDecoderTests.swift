import CommonCrypto
import CryptoKit
import Foundation
import Testing
@testable import BrowserCore

@Suite("Synthetic authentication source admission")
struct OrbitChromiumSecretDecoderTests {
    private let password = Array("synthetic-source-key-material-only".utf8)
    private let cipherA = "763130c97cfbfcfff7384cce3ec0b921dac5b27e2b3af7953dc8e79be42504dd24dce5079e28fb3d39e556b027e7fec69fa0073da36cfcb148a3eed9cef74bbb2a6713"
    private let cipherB = "763130c97cfbfcfff7384cce3ec0b921dac5b27e2b3af7953dc8e79be42504dd24dce5079e28fb3d39e556b027e7fec69fa007876e2b439e6866e2e688b4e344e8c74c"
    private let now: Int64 = 13_437_446_400_000_000

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    private func row(_ cipher: String? = nil) -> ArcSyntheticCookieRow {
        ArcSyntheticCookieRow(host: "login.auth-fixture.test", name: "__Host-synthetic-session",
            encryptedValue: bytes(cipher ?? cipherA), creation: now, lastAccess: now,
            lastUpdate: now, expiry: now + 2_592_000_000_000)
    }

    private func decode(_ row: ArcSyntheticCookieRow) throws -> ArcPreparedSyntheticCookie {
        try ArcChromiumSecretDecoder.decodeSyntheticV24(row, now: now,
            source: ArcSyntheticSourceSecret(password: password))
    }

    @Test("Independent contract vectors decode binary host hash before UTF-8")
    func contractVectors() throws {
        for (cipher, expected) in [(cipherA, "synthetic-session-alpha-only"), (cipherB, "synthetic-session-beta-only")] {
            let result = try decode(row(cipher))
            #expect(try result.withValue { Array($0) == Array(expected.utf8) })
            #expect(result.sameSite.cefValue == 3)
            #expect(result.normalization == [.creationRegenerated, .accessRegenerated, .updateRegenerated, .sourceTypeToOther, .expiryMayBeClamped])
            #expect(result.sourceType == 1)
            #expect(result.normalizedSourceType == 3)
        }
    }

    @Test("SQL SameSite values are semantically converted", arguments: [-1, 0, 1, 2])
    func sameSite(_ value: Int) throws {
        var input = row(); input.sameSite = value
        #expect(try decode(input).sameSite.cefValue == value + 1)
    }

    @Test("Already-Other source type is supported without claiming a transformation")
    func sourceTypeOther() throws {
        var input = row(); input.sourceType = 3
        let prepared = try decode(input)
        #expect(prepared.sourceType == 3)
        #expect(!prepared.normalization.contains(.sourceTypeToOther))
        input.sourceType = 0
        #expect(throws: ArcAuthenticationError.unsupportedSourceMetadata) { try decode(input) }
    }

    @Test("Unsupported fields fail before asking for source key")
    func admissionBeforeKey() throws {
        var variants: [(ArcSyntheticCookieRow, ArcAuthenticationError)] = []
        var input = row(); input.schemaVersion = 25; variants.append((input, .unsupportedSchema))
        input = row(); input.compatibleVersion = 23; variants.append((input, .unsupportedSchema))
        input = row(); input.partitionSite = "https://top.test"; variants.append((input, .unsupportedPartition))
        input = row(); input.crossSiteAncestor = true; variants.append((input, .unsupportedPartition))
        input = row(); input.deviceBound = true; variants.append((input, .reauthenticationRequired))
        input = row(); input.sameSite = 3; variants.append((input, .unsupportedSameSite))
        input = row(); input.sourceScheme = 1; variants.append((input, .unsupportedSourceMetadata))
        input = row(); input.sourcePort = 8443; variants.append((input, .unsupportedSourceMetadata))
        input = row(); input.sourceType = 4; variants.append((input, .unsupportedSourceMetadata))
        input = row(); input.creation = Int64.max; variants.append((input, .invalidTime))
        input = row(); input.plaintextValue = [65]; variants.append((input, .ambiguousValue))
        input = row(); input.encryptedValue[0] = 0; variants.append((input, .unsupportedCiphertext))
        input = row(); input.host = "personal.example.com"; variants.append((input, .syntheticOnly))
        for (candidate, error) in variants {
            let source = ArcSyntheticSourceSecret(password: password)
            #expect(throws: error) { try ArcChromiumSecretDecoder.decodeSyntheticV24(candidate, now: now, source: source) }
            #expect(source.accessCount == 0)
        }
    }

    @Test("Wrong, missing and destroyed source keys have no fallback")
    func unavailableKeys() throws {
        let source = ArcSyntheticSourceSecret(password: Array("synthetic-wrong-key-only".utf8))
        // Rejection can be padding or host binding; no universal wrong-key claim follows.
        #expect(throws: ArcAuthenticationError.decryptionFailed) {
            try ArcChromiumSecretDecoder.decodeSyntheticV24(row(), now: now, source: source)
        }
        #expect(source.accessCount == 1)
        source.destroy()
        #expect(throws: ArcAuthenticationError.sourceKeyUnavailable) {
            try ArcChromiumSecretDecoder.decodeSyntheticV24(row(), now: now, source: source)
        }
        #expect(throws: ArcAuthenticationError.sourceKeyUnavailable) {
            try ArcChromiumSecretDecoder.decodeSyntheticV24(row(), now: now,
                source: ArcSyntheticSourceSecret(password: []))
        }
    }

    @Test("Exact host bytes including leading dot are authenticated")
    func hostMismatch() throws {
        var input = row(); input.host = "other.auth-fixture.test"
        #expect(throws: ArcAuthenticationError.hostHashMismatch) { try decode(input) }
        input.host = ".login.auth-fixture.test"; input.name = "ordinary"
        #expect(throws: ArcAuthenticationError.hostHashMismatch) { try decode(input) }
    }

    @Test("SameSite None security and Host prefix policy have independent cases")
    func independentPolicy() throws {
        var input = row(); input.name = "ordinary"; input.sameSite = 0; input.secure = false
        #expect(throws: ArcAuthenticationError.insecureSameSiteNone) { try decode(input) }
        input.secure = true
        #expect(try decode(input).sameSite.cefValue == 1)
        input = row(); input.sameSite = 1; input.secure = false
        #expect(throws: ArcAuthenticationError.invalidPrefix) { try decode(input) }
    }

    @Test("Chromium prefix policy is ASCII case insensitive and includes Http prefixes")
    func prefixPolicy() throws {
        for name in ["__secure-synthetic", "__host-synthetic", "__HTTP-synthetic", "__Host-Http-synthetic"] {
            var input = row(); input.name = name; input.secure = false; input.sameSite = 1
            #expect(throws: ArcAuthenticationError.invalidPrefix) { try decode(input) }
        }
        for name in ["__Http-synthetic", "__hOSt-HTTP-synthetic"] {
            var input = row(); input.name = name; input.httpOnly = false
            #expect(throws: ArcAuthenticationError.invalidPrefix) { try decode(input) }
            input.httpOnly = true
            _ = try decode(input)
        }
    }

    @Test("Expired rows are classified without resurrection or key access")
    func expiryAndSession() throws {
        var input = row(); input.expiry = now
        #expect(throws: ArcAuthenticationError.skippedExpired) { try decode(input) }
        input = row(); input.hasExpiry = false; input.persistent = false; input.expiry = 0
        #expect(try decode(input).expiry == nil)
        input.persistent = true
        #expect(throws: ArcAuthenticationError.invalidTime) { try decode(input) }
    }

    // Encryption is test-only, independent of the decoder's implementation.
    private func encrypt(_ clear: [UInt8]) throws -> [UInt8] {
        let key = bytes("84aa89c92f524caeb41c6c9755bfcad5")
        let iv = [UInt8](repeating: 32, count: 16)
        var output = [UInt8](repeating: 0, count: clear.count + 16)
        var size = 0
        let capacity = output.count
        let status = key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in clear.withUnsafeBytes { clear in
            output.withUnsafeMutableBytes { output in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key.baseAddress, 16, iv.baseAddress, clear.baseAddress, clear.count, output.baseAddress, capacity, &size)
            }
        } } }
        #expect(status == kCCSuccess)
        return Array("v10".utf8) + output.prefix(size)
    }

    @Test("Padding, UTF-8, control characters and bounds fail closed; empty value is valid")
    func malformedPayloads() throws {
        let hash = Array(SHA256.hash(data: Data("login.auth-fixture.test".utf8)))
        var input = row(); input.encryptedValue.removeLast()
        #expect(throws: ArcAuthenticationError.unsupportedCiphertext) { try decode(input) }
        input = row(); input.encryptedValue = try encrypt(hash + [65])
        input.encryptedValue[input.encryptedValue.count - 17] ^= 1
        #expect(throws: ArcAuthenticationError.decryptionFailed) { try decode(input) }
        input = row(); input.encryptedValue = try encrypt(hash + [0xff])
        #expect(throws: ArcAuthenticationError.invalidValue) { try decode(input) }
        input.encryptedValue = try encrypt(hash + [0])
        #expect(throws: ArcAuthenticationError.invalidValue) { try decode(input) }
        input.encryptedValue = try encrypt(hash)
        let empty = try decode(input)
        #expect(try empty.withValue { $0.isEmpty })
        empty.destroy()
        #expect(throws: ArcAuthenticationError.secretDestroyed) { try empty.withValue { $0.count } }
        input = row(); input.encryptedValue = [UInt8](repeating: 0, count: 8193)
        #expect(throws: ArcAuthenticationError.sizeLimit) { try decode(input) }
        input = row(); input.path = "/wrong;path"
        #expect(throws: ArcAuthenticationError.invalidCookie) { try decode(input) }
    }

    @Test("Descriptions, debug output, reflection and errors disclose no row payload")
    func redaction() throws {
        let input = row(); let result = try decode(input)
        let output = String(describing: input) + String(reflecting: input)
            + String(describing: result) + String(reflecting: result)
            + String(describing: Mirror(reflecting: result).children.map(\.label))
        for sentinel in [input.host, input.name, "synthetic-session-alpha-only", "c97cfbfc"] {
            #expect(!output.contains(sentinel))
        }
    }

    @Test("Plaintext and domain semantics remain explicit; unsupported syntax is never normalized")
    func plaintextAndIdentity() throws {
        var input = row(); input.encryptedValue = []; input.plaintextValue = Array("synthetic-plain-only".utf8)
        input.name = "ordinary"; input.host = ".auth-fixture.test"; input.path = "/scoped"
        let prepared = try decode(input)
        #expect(!prepared.hostOnly)
        #expect(prepared.path == "/scoped")
        #expect(try prepared.withValue { Array($0) == input.plaintextValue })
        for host in ["UPPER.test", "bad..test", "-bad.test", "bad-.test", "a/test.test", "test"] {
            input.host = host
            #expect(throws: (any Error).self) { try decode(input) }
        }
        input = row(); input.name = "ordinary"; input.priority = 9
        #expect(throws: ArcAuthenticationError.invalidCookie) { try decode(input) }
        input = row(); input.lastAccess = -1
        #expect(throws: ArcAuthenticationError.invalidTime) { try decode(input) }
        for path in ["/a/../b", "/./b", "//other.test", "/percent%2f", "/quote\""] {
            input = row(); input.path = path
            #expect(throws: ArcAuthenticationError.invalidCookie) { try decode(input) }
        }
    }
}
