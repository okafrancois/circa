import Darwin
import Foundation

/// An absolute program invocation. Arguments are an array: nothing goes through a shell.
public struct BrowserAICommand: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL

    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

/// Environment for a child program. The app's PATH differs from the user's shell (Finder
/// launches), so the search path is explicit. Markers of a parent agent session are removed so
/// the program does not believe it runs nested inside another one.
public enum BrowserAIEnvironment {
    static let removedKeys: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_CODE_SESSION_ID",
        "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "CODEX_THREAD_ID", "CODEX_CI",
    ]
    public static let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public static func make(base: [String: String], searchPath: [String]) -> [String: String] {
        var environment = base.filter { !removedKeys.contains($0.key) }
        var seen = Set<String>()
        environment["PATH"] = (searchPath + systemPath).filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        return environment
    }
}

public struct BrowserAIProcessResult: Equatable, Sendable {
    public var status: Int32?
    public var output: Data
    public var timedOut: Bool
    public var text: String { String(decoding: output, as: UTF8.self) }
}

/// A child program with newline-delimited stdout, writable stdin and discarded stderr.
/// stderr is drained and dropped: programs may print account details there.
public final class BrowserAIProcess: @unchecked Sendable {
    public let lines: AsyncStream<Data>
    public var processIdentifier: Int32 { process.processIdentifier }

    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private let errors: FileHandle
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    /// Separate from `lock`: a write blocked on a full pipe must not stop stdout from draining.
    private let inputLock = NSLock()
    private var buffer: BrowserAILineBuffer
    private var linesFinished = false
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var inputClosed = false

    public init(_ command: BrowserAICommand, lineLimit: Int = 16 << 20) throws {
        buffer = BrowserAILineBuffer(limit: lineLimit)
        (lines, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        // A program that exits early must not kill the app with SIGPIPE on the next write.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = command.workingDirectory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        output.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
        errors.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] process in self?.exited(process.terminationStatus) }
        do { try process.run() }
        catch {
            output.readabilityHandler = nil
            errors.readabilityHandler = nil
            continuation.finish()
            throw error
        }
        Self.register(self)
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [ObjectIdentifier: BrowserAIProcess] = [:]

    private static func register(_ process: BrowserAIProcess) {
        registryLock.lock(); registry[ObjectIdentifier(process)] = process; registryLock.unlock()
    }

    private static func unregister(_ process: BrowserAIProcess) {
        registryLock.lock(); registry[ObjectIdentifier(process)] = nil; registryLock.unlock()
    }

    /// Programs still running, for the app's synchronous quit path.
    public static var runningCount: Int { registryLock.lock(); defer { registryLock.unlock() }; return registry.count }

    /// Quit path: close every program's input and send SIGTERM without waiting. `codex
    /// app-server` and `claude` both exit on SIGTERM; a closed pipe also ends them.
    public static func terminateAll() {
        registryLock.lock(); let processes = Array(registry.values); registryLock.unlock()
        for process in processes {
            process.closeInput()
            process.signal(SIGTERM)
        }
    }

    deinit {
        output.readabilityHandler = nil
        errors.readabilityHandler = nil
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return exitStatus == nil }

    /// Writes one complete message. Returns false when the program no longer reads its input.
    @discardableResult
    public func write(_ data: Data) -> Bool {
        guard isRunning else { return false }
        inputLock.lock(); defer { inputLock.unlock() }
        guard !inputClosed else { return false }
        var written = 0
        let ok = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while written < raw.count {
                let result = Darwin.write(input.fileDescriptor, base + written, raw.count - written)
                if result > 0 { written += result }
                else if result < 0 && errno == EINTR { continue }
                else { return false }
            }
            return true
        }
        return ok
    }

    public func closeInput() {
        inputLock.lock(); defer { inputLock.unlock() }
        guard !inputClosed else { return }
        inputClosed = true
        try? input.close()
    }

    public func signal(_ value: Int32) {
        lock.lock(); let running = exitStatus == nil; lock.unlock()
        if running { kill(process.processIdentifier, value) }
    }

    /// SIGTERM, then SIGKILL after `grace`. Returns the exit status.
    @discardableResult
    public func terminate(grace: TimeInterval = 1) async -> Int32 {
        closeInput()
        signal(SIGTERM)
        let kill = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(grace, 0) * 1_000_000_000))
            self?.signal(SIGKILL)
        }
        let status = await waitForExit()
        kill.cancel()
        return status
    }

    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { waiter in
            lock.lock()
            if let exitStatus { lock.unlock(); waiter.resume(returning: exitStatus); return }
            exitWaiters.append(waiter)
            lock.unlock()
        }
    }

    private func receive(_ data: Data) {
        if data.isEmpty { finishLines(); return }
        lock.lock()
        let complete = buffer.append(data)
        lock.unlock()
        for line in complete { continuation.yield(line) }
    }

    private func finishLines() {
        lock.lock()
        guard !linesFinished else { lock.unlock(); return }
        linesFinished = true
        output.readabilityHandler = nil
        let last = buffer.finish()
        lock.unlock()
        if let last { continuation.yield(last) }
        continuation.finish()
    }

    private func exited(_ status: Int32) {
        Self.unregister(self)
        lock.lock()
        exitStatus = status
        let waiters = exitWaiters
        exitWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: status) }
        // A descendant may keep stdout open after the program exits. Do not wait for it forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.finishLines() }
    }

    /// Runs a short command to completion, with a deadline and a bounded output.
    public static func run(_ command: BrowserAICommand, timeout: TimeInterval,
                           outputLimit: Int = 1 << 20) async -> BrowserAIProcessResult {
        guard let process = try? BrowserAIProcess(command, lineLimit: outputLimit) else {
            return BrowserAIProcessResult(status: nil, output: Data(), timedOut: false)
        }
        process.closeInput()
        let expired = BrowserAIFlag()
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            expired.set()
            await process.terminate(grace: 0.5)
        }
        var output = Data()
        for await line in process.lines where output.count < outputLimit {
            output.append(line)
            output.append(0x0A)
        }
        let status = await process.waitForExit()
        timer.cancel()
        return BrowserAIProcessResult(status: expired.value ? nil : status, output: output, timedOut: expired.value)
    }
}

final class BrowserAIFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// A private, empty working directory for the programs: they never start in a folder that holds
/// the user's files, project instructions or settings. Removed on shutdown.
public final class BrowserAIWorkspace: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()

    public init(parent: URL = FileManager.default.temporaryDirectory) {
        root = parent.appendingPathComponent("circa-ai-" + UUID().uuidString, isDirectory: true)
    }

    /// The app-server process directory.
    public func rootDirectory() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    /// A fresh empty directory for one turn.
    public func makeTurnDirectory() throws -> URL {
        let directory = try rootDirectory().appendingPathComponent("turn-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    public func remove(_ directory: URL) {
        guard directory.path.hasPrefix(root.path + "/") else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: root)
    }
}
