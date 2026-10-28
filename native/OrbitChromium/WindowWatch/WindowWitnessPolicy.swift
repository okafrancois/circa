import Foundation

/// A visible run grants one root-process window a capability; helpers never inherit it.
enum WindowWitnessPolicy {
    static func unexpected(windows: [[String: Int]], root: Int, capability: [String: Any]?) -> Bool {
        guard windows.count <= 1 else { return true }
        return windows.contains { window in
            capability?["pid"] as? Int != root || capability?["mode"] as? String != "visible-input"
                || window["owner"] != root || window["number"] != capability?["windowNumber"] as? Int
                || (window["number"] ?? 0) <= 0
        }
    }
}

/// Pure deadline policy shared by the real witness and Foundation-only tests.
struct OwnedTerminationSchedule {
    var termAt: Double?
    var killSent = false
    mutating func signal(now: Double, requested: Bool) -> Int32? {
        if termAt == nil && requested { termAt = now; return 15 }
        if let termAt, now >= termAt + 1 && !killSent { killSent = true; return 9 }
        return nil
    }
}

import Darwin

struct ProcessSnapshot: Codable, Equatable {
    let pid: Int32
    /// Parent (attests a system helper as the child of a member); optional in older records.
    var ppid: Int32? = nil
    let uid: UInt32
    let pgid: Int32
    let sid: Int32
    let startSec: UInt64
    let startUsec: UInt64
    let path: String?

    var evidence: [String: Any] {
        ["pid": pid, "ppid": ppid as Any? ?? NSNull(), "uid": uid, "pgid": pgid, "sid": sid,
         "startSec": startSec, "startUsec": startUsec, "path": path as Any? ?? NSNull()]
    }

    /// Kernel executable paths can use /var while clone admission uses canonical /private/var.
    /// Fail closed if the existing file cannot be resolved; attestation still checks its inode.
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func read(_ pid: pid_t) throws -> ProcessSnapshot? {
        func info() throws -> proc_bsdinfo? {
            var value = proc_bsdinfo()
            let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout.size(ofValue: value)))
            guard count == MemoryLayout.size(ofValue: value) else {
                if count == 0 && errno == ESRCH { return nil }
                throw OwnedSessionSupervisor.Failure(reason: "kernel-identity-unavailable", expected: ["pid": pid], observed: ["errno": errno])
            }
            return value
        }
        guard let first = try info() else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard let second = try info() else { return nil }
        guard first.pbi_start_tvsec == second.pbi_start_tvsec && first.pbi_start_tvusec == second.pbi_start_tvusec else {
            throw OwnedSessionSupervisor.Failure(reason: "pid-fingerprint-changed", expected: ["pid": pid, "startSec": first.pbi_start_tvsec],
                                                 observed: ["startSec": second.pbi_start_tvsec])
        }
        if second.pbi_status == UInt32(SZOMB) { return nil }
        let sid = getsid(pid)
        if sid < 0 && errno == ESRCH { return nil }
        let path = length > 0 ? canonicalPath(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) : nil
        return ProcessSnapshot(pid: pid, ppid: Int32(bitPattern: second.pbi_ppid), uid: second.pbi_uid, pgid: Int32(second.pbi_pgid), sid: sid,
                               startSec: second.pbi_start_tvsec, startUsec: second.pbi_start_tvusec, path: path)
    }
}

struct OwnedProcessIdentity: Decodable {
    let pid: Int32
    let runnerPID: Int32
    let application: String
    let executable: String
    let maximumSeconds: Double
    let observedAtLaunch: ProcessSnapshot?
}

final class OwnedSessionSupervisor {
    let identity: OwnedProcessIdentity
    var onObservation: (([String: Any]) -> Void)?
    var readProcess: (pid_t) throws -> ProcessSnapshot? = ProcessSnapshot.read
    private var known: [pid_t: ProcessSnapshot] = [:]
    init(identity: OwnedProcessIdentity) { self.identity = identity }

    func candidates() throws -> [pid_t] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0 else { throw Failure(reason: "snapshot-unavailable") }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, 4, &processes, &size, nil, 0) == 0 else { throw Failure(reason: "snapshot-unavailable") }
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .filter { $0.kp_eproc.e_pgid == identity.pid }.map { $0.kp_proc.p_pid }
    }

    func liveMembers(_ supplied: [pid_t]? = nil) throws -> [pid_t] {
        var members: [pid_t] = []
        let group = try supplied ?? candidates()
        for pid in group {
            guard let observed = try readProcess(pid) else {
                onObservation?(["event": "candidate-retired", "pid": pid]); continue
            }
            let original = identity.observedAtLaunch
            let fingerprintChanged = pid == identity.pid && original != nil
                && (observed.startSec != original!.startSec || observed.startUsec != original!.startUsec)
            let attestation = GroupMemberAttestation.attest(
                path: observed.path, pid: pid, ppid: observed.ppid, leader: identity.pid, executable: identity.executable,
                application: identity.application, group: Set(group))
            let allowed = attestation != nil
            if fingerprintChanged || observed.uid != getuid() || observed.sid != identity.pid || observed.pgid != identity.pid || !allowed {
                guard let rechecked = try readProcess(pid) else {
                    onObservation?(["event": "candidate-retired-on-recheck", "pid": pid]); continue
                }
                throw Failure(reason: "live-group-member-mismatch", expected: ["pgid": identity.pid, "sid": identity.pid,
                              "uid": getuid(), "executable": identity.executable, "application": identity.application],
                              observed: ["first": observed.evidence, "rechecked": rechecked.evidence])
            }
            if known[pid] != observed {
                onObservation?(["event": "member-admitted", "identity": observed.evidence, "attestation": attestation!.rawValue])
                known[pid] = observed
            }
            members.append(pid)
        }
        return members
    }

    func send(_ signal: Int32) throws {
        guard !(try liveMembers()).isEmpty else { return }
        if kill(-identity.pid, signal) != 0 && errno != ESRCH { throw Failure(reason: "signal-failed", observed: ["errno": errno]) }
    }

    struct Failure: Error {
        let reason: String
        private let expectedJSON: Data
        private let observedJSON: Data
        init(reason: String, expected: [String: Any] = [:], observed: [String: Any] = [:]) {
            self.reason = reason
            expectedJSON = (try? JSONSerialization.data(withJSONObject: expected)) ?? Data("{}".utf8)
            observedJSON = (try? JSONSerialization.data(withJSONObject: observed)) ?? Data("{}".utf8)
        }
        var evidence: [String: Any] {
            ["reason": reason, "expected": (try? JSONSerialization.jsonObject(with: expectedJSON)) ?? [:],
             "observed": (try? JSONSerialization.jsonObject(with: observedJSON)) ?? [:]]
        }
    }
}

/// How a live member of the owned session group is attested (CHROMIUM-APP-R2,
/// BL-LAB-WITNESS-CHROMIUM-CHILDREN); same rules as `member_attestation` of the lab runner.
/// - `/usr/bin/profiles status -type enrollment` runs once per Chromium process at start-up
///   (base/enterprise_util_mac.mm): admitted only at that exact sealed-system path, root-owned and
///   not writable by others, as the child of another member of the group.
/// - The code-signing clone (MacAppCodeSignClone, code_sign_clone_manager.h) under
///   /private/var/folders/…/<id>.code_sign_clone/ has a hard link of the attested main
///   executable: admitted only when that clone's main executable is the attested file.
enum GroupMemberAttestation: String {
    case executable
    case bundle
    case codeSignCloneExecutable = "code-sign-clone-executable"
    case codeSignCloneBundle = "code-sign-clone-bundle"
    case systemHelper = "system-helper"

    struct FileIdentity: Equatable { let device: UInt64; let inode: UInt64 }

    static let systemHelpers: Set<String> = ["/usr/bin/profiles"]
    static let cloneRoot = "/private/var/folders/"

    static func fileIdentity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    static func isSystemBinary(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_uid == 0 && info.st_mode & 0o022 == 0
    }

    /// The cloned bundle containing `path`, or nil outside a code-signing clone.
    static func codeSignCloneBundle(_ path: String) -> String? {
        guard path.hasPrefix(cloneRoot) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let clone = parts.firstIndex(where: { $0.hasSuffix(".code_sign_clone") }),
              let bundle = parts[(clone + 1)...].firstIndex(where: { $0.hasSuffix(".app") || $0.hasSuffix(".app.bundle") })
        else { return nil }
        return "/" + parts[...bundle].joined(separator: "/")
    }

    static func attest(path: String?, pid: Int32, ppid: Int32?, leader: Int32, executable: String, application: String,
                       group: Set<Int32>, identity: (String) -> FileIdentity? = fileIdentity,
                       systemBinary: (String) -> Bool = isSystemBinary) -> GroupMemberAttestation? {
        guard let path else { return nil }
        let helper = pid != leader
        if path == executable { return .executable }
        if helper && path.hasPrefix(application + "/") { return .bundle }
        if let clone = codeSignCloneBundle(path) {
            let main = clone + "/Contents/MacOS/" + (executable as NSString).lastPathComponent
            if let cloned = identity(main), cloned == identity(executable) {
                if path == main { return .codeSignCloneExecutable }
                if helper && path.hasPrefix(clone + "/") { return .codeSignCloneBundle }
            }
        }
        if helper, systemHelpers.contains(path), let ppid, group.contains(ppid), systemBinary(path) { return .systemHelper }
        return nil
    }
}
