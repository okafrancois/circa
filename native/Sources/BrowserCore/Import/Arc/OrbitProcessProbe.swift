import Darwin
import Foundation

/// Detects a running Arc. Passive: lists processes and reads Chromium's singleton lock, never
/// sends a nonzero signal or an Apple event. Unknown usage refuses import, as does a running Arc.
public protocol ArcRunningProbe: Sendable {
    func isArcRunning(sourceRoot: URL) -> Bool
}

/// Detects a running Orbit that uses a given session file (offline tools refuse to write under it).
public protocol OrbitTargetUsageProbe: Sendable {
    func isInUse(sessionFile: URL) -> Bool
}

public struct ArcSystemRunningProbe: ArcRunningProbe, OrbitTargetUsageProbe {
    public init() {}

    /// A running Arc only writes its own data folder: the process check applies to that folder
    /// (resolved, so an alias of it counts too). Any folder whose Chromium singleton lock is live
    /// (copied while Arc ran, or Arc started with another data folder) is refused as well.
    public func isArcRunning(sourceRoot: URL) -> Bool {
        if Self.canonicalPath(sourceRoot) == Self.canonicalPath(ArcSourceSnapshot.defaultSourceRoot) {
            guard let processes = ArcProcessList.processes() else { return true }
            for process in processes where process.command == "Arc" {
                // Arc's main executable is `Arc.app/Contents/MacOS/Arc`; helpers have other names.
                guard let path = ArcProcessList.arguments(of: process.pid)?.executable else { return true }
                if path.hasSuffix(".app/Contents/MacOS/Arc") { return true }
            }
        }
        return Self.singletonLockIsLive(sourceRoot.appendingPathComponent("User Data/SingletonLock"))
    }

    static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Chromium's `SingletonLock` is a symbolic link to `<hostname>-<pid>` while the browser runs
    /// (Chromium `process_singleton_posix.cc`; not observed on Arc's own files).
    static func singletonLockIsLive(_ lock: URL) -> Bool {
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = readlink(lock.path, &buffer, buffer.count)
        // Only a missing entry proves there is no lock. Failed or truncated reads remain unknown.
        guard length >= 0 else { return errno != ENOENT }
        guard length > 0, length < buffer.count,
              let target = String(bytes: buffer[0..<length].map { UInt8(bitPattern: $0) }, encoding: .utf8) else { return true }
        guard let separator = target.lastIndex(of: "-"), let pid = pid_t(target[target.index(after: separator)...]),
              pid > 0 else { return true }
        var host = [CChar](repeating: 0, count: 256)
        guard gethostname(&host, host.count) == 0, let end = host.firstIndex(of: 0), end > 0,
              let hostName = String(bytes: host[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8),
              String(target[..<separator]) == hostName else { return true }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    public func isInUse(sessionFile: URL) -> Bool {
        let target = sessionFile.standardizedFileURL.resolvingSymlinksInPath().path
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .standardizedFileURL.resolvingSymlinksInPath().path
        let parent = sessionFile.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let isDefaultLocation = parent.deletingLastPathComponent().path == support
            && (parent.lastPathComponent.hasPrefix("Orbit") || parent.lastPathComponent == ProductIdentity.dataDirectoryName)
        guard let processes = ArcProcessList.processes() else { return true }
        for process in processes where process.command.hasPrefix("Orbit") || process.command.hasPrefix(ProductIdentity.displayName) {
            // Unreadable arguments cannot rule out this explicit target, including custom locations.
            guard let arguments = ArcProcessList.arguments(of: process.pid)?.arguments else { return true }
            if let index = arguments.firstIndex(of: "--session-file"), arguments.indices.contains(index + 1) {
                let used = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL.resolvingSymlinksInPath().path
                if used == target { return true }
            } else if !arguments.contains("--ephemeral"), isDefaultLocation {
                return true
            }
        }
        return false
    }
}

enum ArcProcessList {
    struct Process { let pid: pid_t; let command: String }

    static func processes() -> [Process]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        let stride = MemoryLayout<kinfo_proc>.stride
        let maximumBytes = 64 * 1024 * 1024
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > 0, size <= maximumBytes - 16 * stride, size % stride == 0 else { return nil }
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        let capacity = entries.count * stride
        size = capacity
        guard sysctl(&mib, u_int(mib.count), &entries, &size, nil, 0) == 0,
              size > 0, size < capacity, size % stride == 0 else { return nil }
        var result: [Process] = []
        for entry in entries.prefix(size / stride) {
            guard entry.kp_proc.p_pid >= 0 else { return nil }
            // A zombie cannot hold a session or write files. Its argv is unreadable, so
            // keeping it would make every offline target look busy until its parent reaps it.
            if Int32(entry.kp_proc.p_stat) == SZOMB { continue }
            var command = entry.kp_proc.p_comm
            let name: String? = withUnsafeBytes(of: &command) { raw in
                guard let end = raw.firstIndex(of: 0) else { return nil }
                return String(bytes: raw[..<end], encoding: .utf8)
            }
            guard let name else { return nil }
            result.append(Process(pid: entry.kp_proc.p_pid, command: name))
        }
        guard result.contains(where: { $0.pid == getpid() }) else { return nil }
        return result
    }

    /// Executable path and argv from `KERN_PROCARGS2` (same-user processes only).
    static func arguments(of pid: pid_t) -> (executable: String, arguments: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= 1024 * 1024 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= buffer.count else { return nil }
        let count = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard count > 0, count <= 16384 else { return nil }
        var index = MemoryLayout<Int32>.size
        func string() -> String? {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            guard index < size else { return nil }
            return String(bytes: buffer[start..<index], encoding: .utf8)
        }
        guard let executable = string(), !executable.isEmpty else { return nil }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < size {
            guard let argument = string() else { return nil }
            arguments.append(argument)
            index += 1
        }
        guard arguments.count == count else { return nil }
        return (executable, arguments)
    }
}
