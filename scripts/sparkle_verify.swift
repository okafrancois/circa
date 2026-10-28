import CryptoKit
import Foundation

// Only public data enters argv. The private signing key stays in a file or the Keychain.
let arguments = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: arguments[1])!)
let signature = Data(base64Encoded: arguments[2])!
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else {
    FileHandle.standardError.write(Data("Archive signature does not match public_ed_key\n".utf8))
    exit(1)
}
