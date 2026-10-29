import BrowserCore
import BrowserEngine
import Darwin
import Foundation
import OrbitChromiumBridge

@MainActor
final class ChromiumPasswordStore: BrowserPasswordStore {
    private weak var engine: ChromiumBrowserEngine?
    private var sessions: [ProfileID: PasswordStoreSession] = [:]
    init(engine: ChromiumBrowserEngine) { self.engine = engine }

    private func session(_ profileID: ProfileID) async throws -> PasswordStoreSession {
        guard let engine, engine.passwordStore != nil else { throw BrowserPasswordStoreError.unavailable }
        await engine.profileReady(profileID)
        guard engine.passwordStore != nil, !engine.refusedProfiles.contains(profileID) else {
            throw BrowserPasswordStoreError.unavailable
        }
        if let session = sessions[profileID], session.handle != 0 { return session }
        let handle = ACRPasswordStoreOpen(engine.profileToken(for: profileID))
        guard handle != 0 else { throw BrowserPasswordStoreError.unavailable }
        let session = PasswordStoreSession(handle: handle)
        sessions[profileID] = session
        guard ACRPasswordStoreObserve(handle, { context, event in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<PasswordStoreSession>.fromOpaque(context).takeUnretainedValue().receive(event)
            }
        }, Unmanaged.passUnretained(session).toOpaque()) == 1 else {
            close(profileID: profileID); throw BrowserPasswordStoreError.unavailable
        }
        return session
    }

    func list(profileID: ProfileID) async throws -> [BrowserPasswordRecord] {
        let session = try await session(profileID)
        return try await perform { ACRPasswordStoreList(session.handle, passwordStoreResult, $0) }
    }
    func add(_ record: BrowserPasswordRecord, profileID: ProfileID) async throws {
        try await write(1, record: record, key: nil, profileID: profileID)
    }
    func update(_ record: BrowserPasswordRecord, replacing key: BrowserPasswordKey, profileID: ProfileID) async throws {
        try await write(2, record: record, key: key, profileID: profileID)
    }
    func remove(_ key: BrowserPasswordKey, profileID: ProfileID) async throws {
        try await write(3, record: nil, key: key, profileID: profileID)
    }
    private func write(_ operation: Int32, record: BrowserPasswordRecord?, key: BrowserPasswordKey?, profileID: ProfileID) async throws {
        let session = try await session(profileID)
        let value = record.map(PasswordRecordBuffer.init)
        let old = key.map { PasswordRecordBuffer(.init(primaryKey: $0)) }
        _ = try await perform { context in
            defer { value?.clear(); old?.clear() }
            return ACRPasswordStoreWrite(session.handle, operation, value?.pointer, old?.pointer, passwordStoreResult, context)
        }
    }
    func changes(profileID: ProfileID) async throws -> AsyncStream<BrowserPasswordStoreChange> {
        let session = try await session(profileID)
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            session.listeners[id] = continuation
            continuation.onTermination = { [weak session] _ in
                Task { @MainActor in session?.listeners[id] = nil }
            }
        }
    }
    func close(profileID: ProfileID) {
        guard let session = sessions.removeValue(forKey: profileID) else { return }
        ACRPasswordStoreClose(session.handle)
        session.receive(3)
    }
    func closeAll() { for profileID in Array(sessions.keys) { close(profileID: profileID) } }

    private func perform(_ call: (UnsafeMutableRawPointer) -> Int32) async throws -> [BrowserPasswordRecord] {
        try await withCheckedThrowingContinuation { continuation in
            let box = Unmanaged.passRetained(PasswordStoreResult(continuation))
            if call(box.toOpaque()) != 1 {
                box.takeRetainedValue().continuation.resume(throwing: BrowserPasswordStoreError.unavailable)
            }
        }
    }
}

@MainActor
private final class PasswordStoreSession {
    var handle: UInt64
    var listeners: [UUID: AsyncStream<BrowserPasswordStoreChange>.Continuation] = [:]
    init(handle: UInt64) { self.handle = handle }
    func receive(_ event: Int32) {
        let change: BrowserPasswordStoreChange = event == 3 ? .closed : event == 2 ? .retained : .changed
        for continuation in listeners.values {
            continuation.yield(change)
            if event == 3 { continuation.finish() }
        }
        if event == 3 { handle = 0; listeners.removeAll() }
    }
}

@MainActor
private final class PasswordStoreResult {
    let continuation: CheckedContinuation<[BrowserPasswordRecord], any Error>
    init(_ continuation: CheckedContinuation<[BrowserPasswordRecord], any Error>) { self.continuation = continuation }
}

private func passwordStoreResult(_ context: UnsafeMutableRawPointer?, _ status: Int32,
                                 _ records: UnsafePointer<orbit_password_record_t>?, _ count: UInt32) {
    guard let context else { return }
    let address = UInt(bitPattern: context)
    let response: Result<[BrowserPasswordRecord], BrowserPasswordStoreError> = {
        guard status == 1 else {
            return .failure(status == -2 ? .cancelled : status == -3 ? .conflict : .backendFailure)
        }
        func text(_ span: orbit_password_text_t) -> String {
            guard let data = span.data, span.count != 0 else { return "" }
            return String(decoding: UnsafeBufferPointer(start: data, count: Int(span.count)), as: UTF16.self)
        }
        var result: [BrowserPasswordRecord] = []
        if let records {
            for row in UnsafeBufferPointer(start: records, count: Int(count)) {
                guard row.struct_size >= MemoryLayout<orbit_password_record_t>.size,
                      let realm = row.signon_realm, let origin = row.origin_url, let action = row.action_url else {
                    return .failure(.backendFailure)
                }
                result.append(.init(primaryKey: .init(signonRealm: String(cString: realm), originURL: String(cString: origin),
                    usernameElement: text(row.username_element), usernameValue: text(row.username_value), passwordElement: text(row.password_element)),
                    actionURL: String(cString: action), passwordValue: text(row.password_value),
                    dateCreated: row.date_created, dateLastUsed: row.date_last_used, datePasswordModified: row.date_password_modified,
                    blockedByUser: row.blocked_by_user != 0, scheme: row.scheme))
            }
        }
        return .success(result)
    }()
    MainActor.assumeIsolated {
        let box = Unmanaged<PasswordStoreResult>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeRetainedValue()
        switch response {
        case .success(let records): box.continuation.resume(returning: records)
        case .failure(let error): box.continuation.resume(throwing: error)
        }
    }
}

/// Call-scoped buffers; memset_s cannot be removed by the optimizer.
private final class PasswordRecordBuffer {
    let pointer: UnsafeMutablePointer<orbit_password_record_t>
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private var spans: [(UnsafeMutablePointer<UInt16>, Int)] = []
    init(_ value: BrowserPasswordRecord) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: orbit_password_record_t())
        func utf8(_ value: String) -> UnsafePointer<CChar> {
            let bytes = strdup(value)!
            strings.append(bytes); return UnsafePointer(bytes)
        }
        func utf16(_ value: String) -> orbit_password_text_t {
            let count = value.utf16.count
            let bytes = UnsafeMutablePointer<UInt16>.allocate(capacity: max(count, 1))
            for (index, unit) in value.utf16.enumerated() { bytes.advanced(by: index).initialize(to: unit) }
            spans.append((bytes, count))
            return orbit_password_text_t(data: UnsafePointer(bytes), count: UInt32(count))
        }
        pointer.pointee.struct_size = UInt32(MemoryLayout<orbit_password_record_t>.size)
        pointer.pointee.signon_realm = utf8(value.primaryKey.signonRealm)
        pointer.pointee.origin_url = utf8(value.primaryKey.originURL)
        pointer.pointee.action_url = utf8(value.actionURL)
        pointer.pointee.username_element = utf16(value.primaryKey.usernameElement)
        pointer.pointee.username_value = utf16(value.primaryKey.usernameValue)
        pointer.pointee.password_element = utf16(value.primaryKey.passwordElement)
        pointer.pointee.password_value = utf16(value.passwordValue)
        pointer.pointee.date_created = value.dateCreated
        pointer.pointee.date_last_used = value.dateLastUsed
        pointer.pointee.date_password_modified = value.datePasswordModified
        pointer.pointee.blocked_by_user = value.blockedByUser ? 1 : 0
        pointer.pointee.scheme = value.scheme
    }
    func clear() {
        for string in strings { _ = memset_s(string, strlen(string), 0, strlen(string)); free(string) }
        for (span, count) in spans { _ = memset_s(span, count * MemoryLayout<UInt16>.size, 0, count * MemoryLayout<UInt16>.size); span.deinitialize(count: count); span.deallocate() }
        strings.removeAll(); spans.removeAll()
        pointer.pointee = orbit_password_record_t()
    }
    deinit { clear(); pointer.deinitialize(count: 1); pointer.deallocate() }
}
