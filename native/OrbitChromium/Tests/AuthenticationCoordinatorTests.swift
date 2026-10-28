import OrbitChromiumBridge
import BrowserCore
import Foundation

@MainActor
private final class NativeDouble {
    enum Mode { case earlySuccess, earlyThenRefuse, refuse, delayed }
    var mode: Mode = .earlySuccess
    var ready = true
    var fresh = true
    var next: UInt64 = 1
    var callback: ACRAuthCallback?
    var context: UnsafeMutableRawPointer?
    var base = ACRAuthNotice()
    var borrowed = false
    var cancelCount = 0
    var live = false
    func make() -> ChromiumAuthenticationImport {
        ChromiumAuthenticationImport(bridge: .init(token: { [self] in defer { next += 1 }; return next },
            fresh: { [self] _, bytes, persist in
                assert(bytes.length <= 80 && (persist == 0 || persist == 1))
                assert(String(bytes: UnsafeBufferPointer(start: bytes.bytes, count: Int(bytes.length)), encoding: .utf8)!.hasPrefix("Auth-"))
                return fresh ? 1 : 0
            }, ready: { [self] _ in ready }, install: { [self] batch, callback, context in
                let batch = batch.pointee
                assert(batch.version == ACR_AUTH_VERSION && batch.struct_size == MemoryLayout<ACRAuthBatch>.size)
                assert(batch.row_count <= 1)
                if batch.row_count == 1 {
                    let row = batch.rows!.pointee
                    assert(row.same_site == 3 && row.host_only == 1 && row.has_expiry == 0)
                    assert(row.partitioned == 0 && row.source_scheme == 2 && row.source_port == 443 && row.source_type == 1)
                    assert(row.value.length == 8 && UnsafeBufferPointer(start: row.value.bytes, count: 8).allSatisfy { $0 == 65 })
                }
                borrowed = true // Inspect inside borrow; never retain/copy a value pointer.
                base = ACRAuthNotice(struct_size: UInt32(MemoryLayout<ACRAuthNotice>.size), version: ACR_AUTH_VERSION,
                    operation: batch.operation, profile: batch.profile, kind: 1, status: 0,
                    requested: batch.row_count, installed: batch.row_count, observed: batch.row_count, pending: 0)
                if mode == .refuse { return 0 }
                self.callback = callback; self.context = context; live = true
                if mode != .delayed {
                    callback?(context, &base); callback?(context, &base) // Legal early duplicates, before admission returns.
                    live = false
                }
                return mode == .earlyThenRefuse ? 0 : 1
            }, cancel: { [self] _ in cancelCount += 1; return 1 }))
    }
    func send(kind: UInt32, status: Int32, pending: UInt32) {
        assert(live)
        var notice = base; notice.kind = kind; notice.status = status; notice.pending = pending
        callback?(context, &notice)
        if kind == 2 { live = false; callback = nil; context = nil }
    }
}

@main
struct AuthenticationCoordinatorTests {
    @MainActor static func prepared() throws -> ArcPreparedSyntheticCookie {
        var row = ArcSyntheticCookieRow(host: "login.auth-fixture.test", name: "ordinary", encryptedValue: [],
            creation: 1, lastAccess: 1, lastUpdate: 1, expiry: 0)
        row.hasExpiry = false; row.persistent = false; row.plaintextValue = [UInt8](repeating: 65, count: 8)
        return try ArcChromiumSecretDecoder.decodeSyntheticV24(row, now: 100, source: ArcSyntheticSourceSecret(password: []))
    }
    @MainActor static func destroyed(_ cookie: ArcPreparedSyntheticCookie) {
        do { _ = try cookie.withValue { _ in 1 }; assertionFailure("consumed buffer remained available") }
        catch { assert(error as? ArcAuthenticationError == .secretDestroyed) }
    }
    @MainActor static func main() throws {
        guard _isDebugAssertConfiguration() else {
            FileHandle.standardError.write(Data("Authentication coordinator assertions must be enabled.\n".utf8))
            exit(86)
        }
        for mode in [NativeDouble.Mode.earlySuccess, .earlyThenRefuse, .refuse] {
            let native = NativeDouble(); native.mode = mode
            let coordinator = native.make(); let target = coordinator.createFreshSyntheticTarget(for: ProfileID(), persistSession: true)!
            let cookie = try prepared(); let handle = coordinator.submit(target, consuming: [cookie])
            destroyed(cookie)
            assert(native.borrowed && coordinator.activeOperationCount == 0 && handle.isDrained)
            assert(handle.result?.status == (mode == .earlySuccess ? 0 : 1))
            let retry = coordinator.submit(target, consuming: [try prepared()])
            assert(retry.result?.status == 1 && coordinator.activeOperationCount == 0)
        }
        let native = NativeDouble(); native.mode = .delayed
        let coordinator = native.make(); let target = coordinator.createFreshSyntheticTarget(for: ProfileID(), persistSession: false)!
        let cookie = try prepared(); let handle = coordinator.submit(target, consuming: [cookie]); destroyed(cookie)
        assert(handle.result == nil && !handle.isDrained && coordinator.activeOperationCount == 1)
        var updates = 0
        handle.onChange = { _, _ in updates += 1 }
        var invalid = native.base; invalid.version = 99
        native.callback?(native.context, &invalid)
        var short = (UInt32(8), UInt32(ACR_AUTH_VERSION))
        withUnsafeBytes(of: &short) { bytes in
            native.callback?(native.context, bytes.baseAddress!.assumingMemoryBound(to: ACRAuthNotice.self))
        }
        invalid = native.base; invalid.profile += 1
        native.callback?(native.context, &invalid)
        assert(handle.result == nil && updates == 0)
        // A drain notice cannot precede a terminal and make a queued write appear settled.
        var premature = native.base; premature.kind = 2; premature.status = 7
        native.callback?(native.context, &premature)
        assert(handle.result == nil && !handle.isDrained)
        native.send(kind: 1, status: 8, pending: 1)
        native.send(kind: 2, status: 8, pending: 0)
        assert(handle.isDrained && coordinator.activeOperationCount == 0 && updates == 2)

        let cancelled = NativeDouble(); cancelled.mode = .delayed
        let owner = cancelled.make(); let fresh = owner.createFreshSyntheticTarget(for: ProfileID(), persistSession: false)!
        let pending = owner.submit(fresh, consuming: [try prepared()])
        var changes = 0; pending.onChange = { _, _ in changes += 1 }
        pending.cancel(); assert(cancelled.cancelCount == 1)
        cancelled.send(kind: 1, status: 7, pending: 2)
        cancelled.send(kind: 1, status: 7, pending: 2)
        assert(changes == 1 && pending.result?.status == 7 && !pending.isDrained && owner.activeOperationCount == 1)
        cancelled.send(kind: 2, status: 7, pending: 0)
        assert(changes == 2 && pending.isDrained && owner.activeOperationCount == 0)
        pending.cancel(); assert(cancelled.cancelCount == 1)

        let notReady = NativeDouble(); let noReady = notReady.make()
        let waiting = noReady.createFreshSyntheticTarget(for: ProfileID(), persistSession: false)!; notReady.ready = false
        let unready = try prepared(); let refused = noReady.submit(waiting, consuming: [unready]); destroyed(unready)
        assert(refused.result?.status == 1 && !notReady.borrowed && noReady.activeOperationCount == 0)
        let rejected = NativeDouble(); rejected.fresh = false
        assert(rejected.make().createFreshSyntheticTarget(for: ProfileID(), persistSession: false) == nil)
        assert(coordinator.createFreshSyntheticTarget(for: target.profileID, persistSession: false) == nil)
        let foreign = noReady.submit(target, consuming: [try prepared()])
        assert(foreign.result?.status == 1 && !notReady.borrowed)
        let emptyNative = NativeDouble(); let empty = emptyNative.make()
        let emptyTarget = empty.createFreshSyntheticTarget(for: ProfileID(), persistSession: true)!
        let emptyHandle = empty.submit(emptyTarget, consuming: [])
        assert(emptyHandle.result?.status == 0 && emptyHandle.result?.observed == 0 && emptyHandle.isDrained)
        let deadNative = NativeDouble(); let deadOwner = deadNative.make()
        let deadTarget = deadOwner.createFreshSyntheticTarget(for: ProfileID(), persistSession: false)!
        let dead = try prepared(); dead.destroy()
        let deadHandle = deadOwner.submit(deadTarget, consuming: [dead])
        assert(deadHandle.result?.status == 1 && deadHandle.isDrained && !deadNative.borrowed && deadOwner.activeOperationCount == 0)
        print("PASS authentication coordinator: early/refused/duplicate callbacks, bounded borrowing, readiness, cancel/drain (native double only)")
    }
}
