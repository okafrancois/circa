import CommonCrypto
import CryptoKit
import Foundation

/// Chromium 156 macOS OSCrypt v10. Schema 24 binds the complete plaintext to the host.
/// Transplant the bytes unchanged: do not normalize cookie values or partition metadata.
public enum ArcChromiumCookieCipher {
    public static func deriveKey(password: Data) throws -> Data {
        guard !password.isEmpty else { throw ArcAuthenticationError.sourceKeyUnavailable }
        var key = Data(count: 16)
        let salt = Data("saltysalt".utf8)
        let status = password.withUnsafeBytes { password in salt.withUnsafeBytes { salt in
            key.withUnsafeMutableBytes { key in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    password.baseAddress!.assumingMemoryBound(to: CChar.self), password.count,
                    salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    key.baseAddress!.assumingMemoryBound(to: UInt8.self), 16)
            }
        } }
        guard status == kCCSuccess else { throw ArcAuthenticationError.decryptionFailed }
        return key
    }

    public static func encrypt(_ clear: Data, key: Data) throws -> Data {
        Data("v10".utf8) + (try crypt(clear, key: key, operation: CCOperation(kCCEncrypt)))
    }

    public static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.starts(with: Data("v10".utf8)), encrypted.count >= 19,
              (encrypted.count - 3) % 16 == 0 else { throw ArcAuthenticationError.unsupportedCiphertext }
        return try crypt(Data(encrypted.dropFirst(3)), key: key, operation: CCOperation(kCCDecrypt))
    }

    public static func reencrypt(_ encrypted: Data, host: String, sourceKey: Data, targetKey: Data) throws -> Data {
        var clear = try decrypt(encrypted, key: sourceKey)
        defer { clear.resetBytes(in: 0..<clear.count) }
        guard clear.prefix(32) == Data(SHA256.hash(data: Data(host.utf8))) else {
            throw ArcAuthenticationError.hostHashMismatch
        }
        return try encrypt(clear, key: targetKey)
    }

    private static func crypt(_ input: Data, key: Data, operation: CCOperation) throws -> Data {
        guard key.count == 16 else { throw ArcAuthenticationError.decryptionFailed }
        let iv = Data(repeating: 32, count: 16)
        var output = Data(count: input.count + 16)
        let capacity = output.count
        var size = 0
        let status = key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in input.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        key.baseAddress, 16, iv.baseAddress, input.baseAddress, input.count,
                        output.baseAddress, capacity, &size)
            }
        } } }
        guard status == kCCSuccess else { throw ArcAuthenticationError.decryptionFailed }
        output.count = size
        return output
    }
}
