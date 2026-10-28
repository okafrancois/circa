import CommonCrypto
import CryptoKit
import Foundation
import Testing
@testable import BrowserCore

/// Independent synthetic counterexamples; no SQLite, filesystem, provider or runtime access.
@Suite("Exact authentication source independent review")
struct OrbitAuthenticationSourceIndependentReviewTests {
    private let now: Int64 = 13_437_446_400_000_000
    private let host = "review.auth-fixture.test"
    private let password = Array("synthetic-source-key-material-only".utf8)

    private func row() -> ArcSyntheticCookieRow {
        var row = ArcSyntheticCookieRow(host: host, name: "review", encryptedValue: [],
            creation: now, lastAccess: now, lastUpdate: now, expiry: now + 1)
        row.plaintextValue = [65]
        return row
    }

    private func decode(_ row: ArcSyntheticCookieRow, clock: Int64? = nil) throws -> ArcPreparedSyntheticCookie {
        try ArcChromiumSecretDecoder.decodeSyntheticV24(row, now: clock ?? now,
            source: ArcSyntheticSourceSecret(password: password))
    }

    /// Independent fixed public vector key; raw CBC lets tests choose every padding byte.
    private func rawCBC(_ padded: [UInt8]) throws -> [UInt8] {
        let key: [UInt8] = [0x84, 0xaa, 0x89, 0xc9, 0x2f, 0x52, 0x4c, 0xae,
                            0xb4, 0x1c, 0x6c, 0x97, 0x55, 0xbf, 0xca, 0xd5]
        let iv = [UInt8](repeating: 32, count: 16)
        var encrypted = [UInt8](repeating: 0, count: padded.count)
        var written = 0
        let capacity = encrypted.count
        let status = key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in padded.withUnsafeBytes { input in
            encrypted.withUnsafeMutableBytes { output in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0, key.baseAddress,
                    key.count, iv.baseAddress, input.baseAddress, input.count,
                    output.baseAddress, capacity, &written)
            }
        } } }
        try #require(status == kCCSuccess && written == padded.count)
        return Array("v10".utf8) + encrypted
    }

    private func encrypted(_ clear: [UInt8]) throws -> [UInt8] {
        let padding = 16 - clear.count % 16
        return try rawCBC(clear + [UInt8](repeating: UInt8(padding), count: padding))
    }

    @Test("Every legal PKCS7 length works and every nonterminal padding byte is checked",
          arguments: Array(1...16))
    func paddingMatrix(_ padding: Int) throws {
        var input = row(); input.plaintextValue = []
        let value = [UInt8](repeating: 65, count: 16 - padding)
        let clear = Array(SHA256.hash(data: Data(host.utf8))) + value
        let padded = clear + [UInt8](repeating: UInt8(padding), count: padding)
        input.encryptedValue = try rawCBC(padded)
        let prepared = try decode(input)
        #expect(try prepared.withValue { Array($0) == value })
        for index in 0..<padding {
            var corrupt = padded
            // Zero is never a valid pad byte. Include the terminal-byte-zero case.
            corrupt[corrupt.count - 1 - index] = 0
            input.encryptedValue = try rawCBC(corrupt)
            #expect(throws: ArcAuthenticationError.decryptionFailed) { try decode(input) }
        }
        input.encryptedValue = try rawCBC(clear + [UInt8](repeating: 17, count: padding))
        #expect(throws: ArcAuthenticationError.decryptionFailed) { try decode(input) }
    }

    @Test("Binary exact-host binding precedes invalid UTF8 and supports a hash-bound leading dot")
    func hashOrderingAndDomainPositive() throws {
        var input = row(); input.plaintextValue = []
        for count in [0, 1, 31] {
            input.encryptedValue = try encrypted([UInt8](repeating: 0xff, count: count))
            #expect(throws: ArcAuthenticationError.hostHashMismatch) { try decode(input) }
        }
        let wrongHash = Array(SHA256.hash(data: Data("other.auth-fixture.test".utf8)))
        input.encryptedValue = try encrypted(wrongHash + [0xff])
        #expect(throws: ArcAuthenticationError.hostHashMismatch) { try decode(input) }
        input.host = ".review.auth-fixture.test"
        let exactHash = Array(SHA256.hash(data: Data(input.host.utf8)))
        input.encryptedValue = try encrypted(exactHash + [65])
        let prepared = try decode(input)
        #expect(!prepared.hostOnly && prepared.host == input.host)
        #expect(try prepared.withValue { Array($0) == [65] })
    }

    @Test("Each oversized input and unsupported numeric extreme refuses before provider access")
    func independentAdmissionBounds() throws {
        let mutations: [(inout ArcSyntheticCookieRow) -> Void] = [
            { $0.host = String(repeating: "a", count: 255) },
            { $0.name = String(repeating: "a", count: 1025) },
            { $0.path = "/" + String(repeating: "a", count: 1024) },
            { $0.plaintextValue = [UInt8](repeating: 65, count: 4097) },
            { $0.encryptedValue = [UInt8](repeating: 0, count: 8193) },
            { $0.partitionSite = String(repeating: "a", count: 2049) }
        ]
        for mutate in mutations {
            var input = row(); mutate(&input)
            let source = ArcSyntheticSourceSecret(password: password)
            #expect(throws: ArcAuthenticationError.sizeLimit) {
                try ArcChromiumSecretDecoder.decodeSyntheticV24(input, now: now, source: source)
            }
            #expect(source.accessCount == 0)
        }
        for number in [Int.min, -1, 0, 23, 25, Int.max] {
            var input = row(); input.schemaVersion = number
            #expect(throws: ArcAuthenticationError.unsupportedSchema) { try decode(input) }
            input = row(); input.compatibleVersion = number
            #expect(throws: ArcAuthenticationError.unsupportedSchema) { try decode(input) }
        }
        for number in [Int.min, -2, 3, Int.max] {
            var input = row(); input.sameSite = number
            #expect(throws: ArcAuthenticationError.unsupportedSameSite) { try decode(input) }
        }
    }

    @Test("Combined cookie size boundary and individual cookie-octet refusals are independent")
    func valueBoundaries() throws {
        var input = row(); input.name = String(repeating: "n", count: 1024)
        input.plaintextValue = [UInt8](repeating: 65, count: 3072)
        #expect(try decode(input).withValue { $0.count } == 3072)
        input.plaintextValue.append(65)
        #expect(throws: ArcAuthenticationError.invalidValue) { try decode(input) }
        for octet: UInt8 in [0, 9, 10, 13, 32, 34, 44, 59, 92, 127, 255] {
            input = row(); input.plaintextValue = [octet]
            #expect(throws: ArcAuthenticationError.invalidValue) { try decode(input) }
        }
        input = row(); input.plaintextValue = []
        #expect(try decode(input).withValue { $0.isEmpty })
    }

    @Test("Expiry equality does not request a key; session flags and integer time bounds are strict")
    func timePolicy() throws {
        var input = row(); input.expiry = now; input.encryptedValue = Array("v99".utf8); input.plaintextValue = []
        let source = ArcSyntheticSourceSecret(password: [])
        #expect(throws: ArcAuthenticationError.skippedExpired) {
            try ArcChromiumSecretDecoder.decodeSyntheticV24(input, now: now, source: source)
        }
        #expect(source.accessCount == 0)
        for clock in [Int64.min, -1, 0, 265_046_774_400_000_000, Int64.max] {
            #expect(throws: ArcAuthenticationError.invalidTime) { try decode(row(), clock: clock) }
        }
        for hasExpiry in [false, true] {
            for persistent in [false, true] {
                input = row(); input.hasExpiry = hasExpiry; input.persistent = persistent
                input.expiry = hasExpiry ? now + 1 : 0
                if hasExpiry == persistent {
                    #expect(try decode(input).expiry == (hasExpiry ? now + 1 : nil))
                } else {
                    #expect(throws: ArcAuthenticationError.invalidTime) { try decode(input) }
                }
            }
        }
        input = row(); input.hasExpiry = false; input.persistent = false
        #expect(throws: ArcAuthenticationError.invalidTime) { try decode(input) }
    }

    @Test("Host prefixes bind path and domain; admitted source types and priorities remain explicit")
    func prefixAndNormalization() throws {
        for name in ["__Host-review", "__hOsT-hTtP-review"] {
            var input = row(); input.name = name; input.path = "/scoped"
            #expect(throws: ArcAuthenticationError.invalidPrefix) { try decode(input) }
            input.path = "/"; input.host = ".review.auth-fixture.test"
            #expect(throws: ArcAuthenticationError.invalidPrefix) { try decode(input) }
        }
        for sourceType in 1...3 {
            var input = row(); input.sourceType = sourceType
            let prepared = try decode(input)
            #expect(prepared.sourceType == sourceType && prepared.normalizedSourceType == 3)
            #expect(prepared.normalization.contains(.sourceTypeToOther) == (sourceType != 3))
        }
        for priority in 0...2 {
            var input = row(); input.priority = priority
            #expect(try decode(input).priority == priority)
        }
    }

    private func transaction(_ phaseIndex: Int) throws -> ArcAuthenticationTransaction {
        var model = try ArcAuthenticationTransaction(targetProfiles: [ProfileID()], verificationDeadline: 2000)
        let events: [ArcAuthenticationTransaction.Event] = [
            .backupDurable, .beginApply, .awaitRestartVerification, .claimVerifier, .verificationSucceeded
        ]
        if phaseIndex == 6 { try model.recordModelEvent(.rollbackCompleted) }
        else { for event in events.prefix(phaseIndex) { try model.recordModelEvent(event, now: 1000) } }
        return model
    }

    @Test("Every phase-event pair preserves state on refusal and no phase authorizes real mutation")
    func transitionMatrix() throws {
        let events: [ArcAuthenticationTransaction.Event] = [
            .backupDurable, .beginApply, .awaitRestartVerification, .claimVerifier, .verificationSucceeded, .rollbackCompleted
        ]
        let permitted: [Set<Int>] = [[0, 5], [1, 5], [2, 5], [3, 5], [4, 5], [], []]
        for phase in 0...6 {
            let original = try transaction(phase)
            #expect(throws: ArcAuthenticationError.realMutationDisabled) { try original.authorizeRealMutation() }
            for (index, event) in events.enumerated() {
                var candidate = original
                if permitted[phase].contains(index) { try candidate.recordModelEvent(event, now: 1000) }
                else {
                    #expect(throws: ArcAuthenticationError.invalidTransition) { try candidate.recordModelEvent(event, now: 1000) }
                    #expect(candidate == original)
                }
            }
        }
        for phase in [3, 4] {
            for clock: Int64? in [nil, -1, 0, 2000, Int64.max] {
                var candidate = try transaction(phase)
                let original = candidate
                #expect(throws: ArcAuthenticationError.invalidTransition) {
                    try candidate.recordModelEvent(phase == 3 ? .claimVerifier : .verificationSucceeded, now: clock)
                }
                #expect(candidate == original)
            }
        }
    }

    @Test("Malformed JSON errors redact attacker strings through both decoding entry points")
    func journalRedactionAndBounds() throws {
        let original = try transaction(0)
        let encoded = try JSONEncoder().encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["version", "id", "targetProfiles", "verificationDeadline", "phase"] {
            for replacement: Any in ["review-secret-origin.test", NSNull(), ["review-secret-origin.test"]] {
                var corrupt = object; corrupt[key] = replacement
                let bytes = try JSONSerialization.data(withJSONObject: corrupt)
                for bounded in [true, false] {
                    do {
                        _ = try bounded ? ArcAuthenticationTransaction.decodeJournalModel(bytes)
                            : JSONDecoder().decode(ArcAuthenticationTransaction.self, from: bytes)
                        Issue.record("Malformed model was admitted")
                    } catch {
                        #expect(error as? ArcAuthenticationError == .invalidTransition)
                        #expect(!String(reflecting: error).contains("review-secret-origin.test"))
                        #expect(!error.localizedDescription.contains("review-secret-origin.test"))
                    }
                }
            }
        }
        var duplicate = object
        let profiles = try #require(object["targetProfiles"] as? [Any])
        duplicate["targetProfiles"] = profiles + profiles
        #expect(throws: ArcAuthenticationError.invalidTransition) {
            try ArcAuthenticationTransaction.decodeJournalModel(JSONSerialization.data(withJSONObject: duplicate))
        }
        // Valid JSON padded to the exact byte budget, then one byte over it.
        let atLimit = encoded + Data(repeating: 32, count: 32_768 - encoded.count)
        #expect(try ArcAuthenticationTransaction.decodeJournalModel(atLimit) == original)
        #expect(throws: ArcAuthenticationError.sizeLimit) {
            try ArcAuthenticationTransaction.decodeJournalModel(atLimit + Data([32]))
        }
    }

    @Test("Mapping limits and exact directory grammar are independent of display ordering")
    func mappingLimits() throws {
        let registration = UUID()
        let pairs = try (1...65).map { number in
            (try ArcAuthenticationSourceProfile(registration: registration,
                profile: .directory("Profile \(number)")), ProfileID())
        }
        let mapping = try ArcAuthenticationProfileMapping(explicitFreshTargets: Array(pairs.prefix(64)))
        #expect(try mapping.target(for: pairs[63].0) == pairs[63].1)
        #expect(throws: ArcAuthenticationError.invalidMapping) { try mapping.target(for: pairs[64].0) }
        #expect(throws: ArcAuthenticationError.invalidMapping) { try ArcAuthenticationProfileMapping(explicitFreshTargets: pairs) }
        for directory in ["default", "Profile +1", "Profile 1 ", "Profile 1000000000", "Profile ١", "Default/", "Profile 1\0"] {
            #expect(throws: ArcAuthenticationError.invalidMapping) {
                try ArcAuthenticationSourceProfile(registration: registration, profile: .directory(directory))
            }
        }
        #expect(throws: ArcAuthenticationError.invalidTransition) {
            try ArcAuthenticationTransaction(targetProfiles: Set(pairs.map(\.1)), verificationDeadline: 2000)
        }
    }

    @Test("All private wrappers suppress reflection before and after explicit destruction")
    func privateWrappers() throws {
        let source = ArcSyntheticSourceSecret(password: password)
        let input = row()
        let prepared = try decode(input)
        let profile = try ArcAuthenticationSourceProfile(registration: UUID(), profile: .directory("Profile 731"))
        let mapping = try ArcAuthenticationProfileMapping(explicitFreshTargets: [(profile, ProfileID())])
        let values: [any ArcAuthenticationPrivateValue] = [source, input, prepared, profile, mapping]
        for destroyed in [false, true] {
            if destroyed { source.destroy(); prepared.destroy() }
            for value in values {
                #expect(String(describing: value) == "<authentication-private>")
                #expect(String(reflecting: value) == "<authentication-private>")
                #expect(Mirror(reflecting: value).children.isEmpty)
            }
        }
        var called = false
        #expect(throws: ArcAuthenticationError.secretDestroyed) {
            try prepared.withValue { _ in called = true }
        }
        #expect(!called)
    }
}
