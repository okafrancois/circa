import OrbitChromiumBridge
import BrowserCore
import Foundation

/// Source-only privileged coordinator. No UI, source Keychain, generic event, existing-target
/// adoption or product mutation authorization. Decode only after the fresh target becomes ready.
@MainActor
public final class ChromiumAuthenticationImport {
    public struct Result: Equatable, Sendable {
        public let status: Int32
        public let requested: UInt32
        public let installed: UInt32
        public let observed: UInt32
    }
    public struct Target {
        public let profileID: ProfileID
        fileprivate let token: UInt64
        fileprivate let owner: UUID
    }
    public final class Handle {
        public fileprivate(set) var result: Result?
        public fileprivate(set) var isDrained = false
        fileprivate var cancelNative: (() -> Void)?
        public var onChange: ((Result?, Bool) -> Void)?
        public func cancel() { cancelNative?() }
        fileprivate func update() { onChange?(result, isDrained) }
    }
    struct Bridge {
        var token: () -> UInt64
        var fresh: (UInt64, ACRAuthBytes, Int32) -> Int32
        var ready: (UInt64) -> Bool
        var install: (UnsafePointer<ACRAuthBatch>, ACRAuthCallback?, UnsafeMutableRawPointer?) -> Int32
        var cancel: (UInt64) -> Int32
    }
    private let bridge: Bridge
    private let identity = UUID()
    private var targets: [UInt64: ProfileID] = [:]
    private var usedTargets: Set<UInt64> = []
    private var active: [UInt64: Receipt] = [:]
    var activeOperationCount: Int { active.count }

    public convenience init(runtime: ChromiumRuntime = .shared) {
        self.init(bridge: Bridge(token: { runtime.makeToken() }, fresh: { ACRAuthCreateFreshProfile($0, $1, $2) },
            ready: { runtime.isProfileReady($0) && !runtime.isProfileRefused($0) },
            install: { ACRAuthInstall($0, $1, $2) }, cancel: { ACRAuthCancel($0) }))
    }
    init(bridge: Bridge) { self.bridge = bridge }

    public func createFreshSyntheticTarget(for profileID: ProfileID, persistSession: Bool) -> Target? {
        guard targets.count < 8, !targets.values.contains(profileID) else { return nil }
        let token = bridge.token()
        let name = Array(("Auth-" + UUID().uuidString).utf8)
        let created = name.withUnsafeBufferPointer { bytes in
            bridge.fresh(token, ACRAuthBytes(bytes: bytes.baseAddress, length: UInt32(bytes.count)), persistSession ? 1 : 0)
        }
        guard created == 1 else { return nil }
        targets[token] = profileID
        return Target(profileID: profileID, token: token, owner: identity)
    }
    public func isReady(_ target: Target) -> Bool {
        target.owner == identity && targets[target.token] == target.profileID && bridge.ready(target.token)
    }

    /// Consumes/destroys prepared values synchronously, including refusal. No secret preparation
    /// waits in a continuation, timer, callback context, serialized payload or debug event.
    /// Caller must relinquish aliases; Swift/CEF copies cannot promise complete erasure.
    public func submit(_ target: Target, consuming cookies: [ArcPreparedSyntheticCookie], timeoutMilliseconds: UInt32 = 10_000) -> Handle {
        defer { for cookie in cookies { cookie.destroy() } }
        let handle = Handle()
        guard isReady(target), !usedTargets.contains(target.token),
              active.count < 8, cookies.count <= 64, (10...30_000).contains(timeoutMilliseconds) else {
            handle.result = Result(status: 1, requested: UInt32(min(cookies.count, 64)), installed: 0, observed: 0)
            handle.isDrained = true; return handle
        }
        let operation = bridge.token()
        let receipt = Receipt(operation: operation, profile: target.token, handle: handle)
        active[operation] = receipt // Before calling native: early callbacks are legal.
        usedTargets.insert(target.token)
        receipt.onDrained = { [weak self] in self?.active[operation] = nil }
        let cancel = bridge.cancel
        handle.cancelNative = { _ = cancel(operation) }
        let address = Unmanaged.passRetained(receipt).toOpaque()
        var rows: [ACRAuthCookie] = []
        let accepted: Int32
        do {
            accepted = try borrow(cookies, index: 0, rows: &rows) { rows in
                rows.withUnsafeBufferPointer { buffer in
                    var batch = ACRAuthBatch(struct_size: UInt32(MemoryLayout<ACRAuthBatch>.size), version: ACR_AUTH_VERSION,
                        operation: operation, profile: target.token, rows: buffer.baseAddress,
                        row_count: UInt32(buffer.count), timeout_ms: timeoutMilliseconds)
                    return bridge.install(&batch, { context, notice in
                        guard let context, let notice else { return }
                        // Read only the fixed prefix before copying a potentially shorter ABI.
                        let raw = UnsafeRawPointer(notice)
                        guard raw.load(as: UInt32.self) == MemoryLayout<ACRAuthNotice>.size,
                              raw.load(fromByteOffset: 4, as: UInt32.self) == ACR_AUTH_VERSION else { return }
                        let pointer = UInt(bitPattern: context)
                        let copy = notice.pointee // Numeric fields only, never a cookie/value.
                        MainActor.assumeIsolated {
                            Unmanaged<Receipt>.fromOpaque(UnsafeRawPointer(bitPattern: pointer)!).takeUnretainedValue().receive(copy)
                        }
                    }, address)
                }
            }
        } catch { accepted = 0 } // Never forward provider/model error descriptions.
        receipt.returned(accepted == 1)
        return handle
    }

    private func borrow<T>(_ cookies: [ArcPreparedSyntheticCookie], index: Int, rows: inout [ACRAuthCookie],
                           body: ([ACRAuthCookie]) throws -> T) throws -> T {
        if index == cookies.count { return try body(rows) }
        let cookie = cookies[index]
        let host = Array(cookie.host.utf8), name = Array(cookie.name.utf8), path = Array(cookie.path.utf8)
        return try cookie.withValue { value in
            try host.withUnsafeBufferPointer { host in try name.withUnsafeBufferPointer { name in try path.withUnsafeBufferPointer { path in
                rows.append(ACRAuthCookie(struct_size: UInt32(MemoryLayout<ACRAuthCookie>.size), version: ACR_AUTH_VERSION,
                    host: ACRAuthBytes(bytes: host.baseAddress, length: UInt32(host.count)),
                    name: ACRAuthBytes(bytes: name.baseAddress, length: UInt32(name.count)),
                    path: ACRAuthBytes(bytes: path.baseAddress, length: UInt32(path.count)),
                    value: ACRAuthBytes(bytes: value.baseAddress?.assumingMemoryBound(to: UInt8.self), length: UInt32(value.count)),
                    host_only: cookie.hostOnly ? 1 : 0, secure: cookie.secure ? 1 : 0, http_only: cookie.httpOnly ? 1 : 0,
                    same_site: cookie.sameSite.cefValue, priority: Int32(cookie.priority), has_expiry: cookie.expiry == nil ? 0 : 1,
                    expiry_us: cookie.expiry ?? 0, partitioned: 0,
                    source_scheme: Int32(cookie.sourceScheme), source_port: Int32(cookie.sourcePort), source_type: Int32(cookie.sourceType),
                    creation_us: cookie.creation, last_access_us: cookie.lastAccess, last_update_us: cookie.lastUpdate))
                defer { rows.removeLast() }
                return try borrow(cookies, index: index + 1, rows: &rows, body: body)
            } } }
        }
    }

    private final class Receipt {
        let operation: UInt64, profile: UInt64
        let handle: Handle
        var onDrained: (() -> Void)?
        var returnedValue: Bool?
        var terminal: ACRAuthNotice?
        var drain: ACRAuthNotice?
        var released = false
        init(operation: UInt64, profile: UInt64, handle: Handle) { self.operation = operation; self.profile = profile; self.handle = handle }
        func receive(_ notice: ACRAuthNotice) {
            guard notice.struct_size == MemoryLayout<ACRAuthNotice>.size, notice.version == ACR_AUTH_VERSION,
                  notice.operation == operation, notice.profile == profile,
                  notice.requested <= 64, notice.installed <= notice.requested, notice.observed <= 64, notice.pending <= 2,
                  (0...10).contains(notice.status), !released else { return }
            if notice.kind == 1, terminal == nil { terminal = notice }
            if notice.kind == 2, drain == nil, notice.pending == 0, let terminal, terminal.pending > 0,
               notice.status == terminal.status { drain = notice }
            deliver()
        }
        func returned(_ accepted: Bool) { returnedValue = accepted; deliver() }
        func deliver() {
            guard let accepted = returnedValue, !released else { return }
            let previousResult = handle.result
            let previousDrain = handle.isDrained
            if !accepted {
                handle.result = Result(status: 1, requested: 0, installed: 0, observed: 0)
                handle.isDrained = true
            } else if let terminal {
                if handle.result == nil {
                    handle.result = Result(status: terminal.status, requested: terminal.requested,
                        installed: terminal.installed, observed: terminal.observed)
                }
                handle.isDrained = terminal.pending == 0 || drain != nil
            } else { return }
            if handle.isDrained {
                released = true; handle.cancelNative = nil
                let drained = onDrained; onDrained = nil; drained?()
            }
            if previousResult != handle.result || previousDrain != handle.isDrained { handle.update() }
            if released { Unmanaged.passUnretained(self).release() } // Balances exactly one passRetained.
        }
    }
}
