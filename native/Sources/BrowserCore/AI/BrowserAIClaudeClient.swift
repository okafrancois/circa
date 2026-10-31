import Darwin
import Foundation

/// How Circa runs the unmodified `claude` program: print mode, stream-json in and out, with no
/// tools at all. Flags were checked with `claude --help` and a live turn on Claude Code 2.1.316.
public enum BrowserAIClaudeLaunch {
    /// No built-in tools, no MCP servers, no user/project/local settings, hooks, CLAUDE.md,
    /// skills, plugins or memory, no session saved, and nothing may ask for permission.
    public static let lockdownArguments: [String] = [
        "--tools", "",
        "--strict-mcp-config",
        "--setting-sources", "",
        "--safe-mode",
        "--restricted",
        "--no-session-persistence",
        "--disable-slash-commands",
        "--permission-mode", "dontAsk",
        "--permission-prompts", "none",
        "--no-chrome",
    ]

    public static func turnArguments(model: String?, effort: String?, instructions: String) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                         "--verbose", "--include-partial-messages"] + lockdownArguments
        arguments += ["--system-prompt", instructions]
        if let model { arguments += ["--model", model] }
        if let effort { arguments += ["--effort", effort] }
        return arguments
    }

    /// The program's own sign-in check. Only `loggedIn` and `subscriptionType` are read.
    public static let statusArguments = ["auth", "status", "--json"]

    /// The prompt goes through stdin, never the command line where other processes can read it.
    public static func userMessage(_ prompt: String) -> BrowserAIJSON {
        ["type": "user", "message": ["role": "user", "content": .string(prompt)]]
    }

    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    /// The CLI's documented `--model` aliases, newest family first.
    public static let models: [BrowserAIModel] = [
        BrowserAIModel(provider: .claudeCode, id: "fable", displayName: "Fable", efforts: efforts),
        BrowserAIModel(provider: .claudeCode, id: "opus", displayName: "Opus", efforts: efforts, isDefault: true),
        BrowserAIModel(provider: .claudeCode, id: "sonnet", displayName: "Sonnet", efforts: efforts),
        BrowserAIModel(provider: .claudeCode, id: "haiku", displayName: "Haiku", efforts: efforts),
    ]

    public enum SignIn: Equatable, Sendable {
        case signedIn(plan: String?)
        case signedOut
        case unreadable
    }

    public static func signIn(fromStatus output: String) -> SignIn {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let status = BrowserAIJSON.parse(Data(output[start...end].utf8)), let loggedIn = status["loggedIn"]?.bool else {
            return .unreadable
        }
        return loggedIn ? .signedIn(plan: status["subscriptionType"]?.string) : .signedOut
    }

    /// `rate_limit_event.rate_limit_info`: per-window utilization (0...1) and reset times.
    public static func usage(fromRateLimit info: BrowserAIJSON) -> BrowserAIUsage? {
        func span(_ key: String?) -> BrowserAIUsageWindow.Span? {
            switch key { case "five_hour": .fiveHours; case "seven_day": .week; default: nil }
        }
        func window(_ span: BrowserAIUsageWindow.Span, _ value: BrowserAIJSON) -> BrowserAIUsageWindow? {
            guard let utilization = value["utilization"]?.double else { return nil }
            let percent = utilization <= 1 ? utilization * 100 : utilization
            return BrowserAIUsageWindow(span: span, usedPercent: Int(percent.rounded()), resetsAt: date(value["resetsAt"]))
        }
        var windows: [BrowserAIUsageWindow] = []
        for (key, value) in info["unifiedWindows"]?.object ?? [:] {
            if let span = span(key), let window = window(span, value) { windows.append(window) }
        }
        if let span = span(info["rateLimitType"]?.string), !windows.contains(where: { $0.span == span }),
           let window = window(span, info) {
            windows.append(window)
        }
        windows.sort { $0.span.order < $1.span.order }
        let rejected = info["status"]?.string == "rejected"
        guard !windows.isEmpty || rejected else { return nil }
        return BrowserAIUsage(windows: windows, limitReached: rejected, limitResetsAt: rejected ? date(info["resetsAt"]) : nil)
    }

    static func date(_ value: BrowserAIJSON?) -> Date? {
        guard let seconds = value?.double, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
    }

    /// Classifies a failed run from the program's own result and errors. Message text is matched
    /// only for the documented sign-in failure; it is never kept.
    static func error(resultText: String?, assistantError: String?, usage: BrowserAIUsage?) -> BrowserAIError {
        if assistantError == "authentication_failed" || assistantError == "oauth_org_not_allowed" { return .signedOut }
        if let text = resultText?.lowercased(), text.contains("not logged in") || text.contains("/login") { return .signedOut }
        if usage?.limitReached == true { return .limitReached(resetsAt: usage?.limitResetsAt) }
        if assistantError == "rate_limit" { return .limitReached(resetsAt: usage?.limitResetsAt) }
        return .failed
    }
}

/// What the program reported about tools during the last turn: the injection check.
public struct BrowserAIClaudeTurnAudit: Equatable, Sendable {
    /// Tools and MCP servers listed by the program's init event.
    public var toolsOffered = 0
    public var toolCalls = 0
    public var permissionDenials = 0
    public init() {}
}

/// Claude Code through the user's own `claude` program and its existing sign-in. One process per
/// turn, in an empty private directory.
public actor BrowserAIClaudeClient: BrowserAIProviderClient {
    public nonisolated let id = BrowserAIProviderID.claudeCode
    private let discovery: BrowserAIProgramDiscovery
    private let workspace: BrowserAIWorkspace
    private let baseEnvironment: [String: String]
    private let statusTimeout: TimeInterval
    private let interruptGrace: TimeInterval
    private var lastUsage: BrowserAIUsage?
    private var running: [ObjectIdentifier: BrowserAIProcess] = [:]
    public private(set) var lastArguments: [String] = []
    public private(set) var lastAudit = BrowserAIClaudeTurnAudit()

    public init(discovery: BrowserAIProgramDiscovery, workspace: BrowserAIWorkspace,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                statusTimeout: TimeInterval = 15, interruptGrace: TimeInterval = 3) {
        self.discovery = discovery
        self.workspace = workspace
        self.baseEnvironment = baseEnvironment
        self.statusTimeout = statusTimeout
        self.interruptGrace = interruptGrace
    }

    public func status(refresh: Bool) async -> BrowserAIProviderStatus {
        guard let location = await discovery.locate(.claude, refresh: refresh) else {
            return BrowserAIProviderStatus(id: id, state: .notInstalled)
        }
        let directory = (try? workspace.rootDirectory()) ?? FileManager.default.temporaryDirectory
        let result = await BrowserAIProcess.run(BrowserAICommand(executable: location.url,
            arguments: BrowserAIClaudeLaunch.statusArguments, environment: environment(location), workingDirectory: directory),
            timeout: statusTimeout, outputLimit: 64 << 10)
        let state: BrowserAIProviderState = switch BrowserAIClaudeLaunch.signIn(fromStatus: result.text) {
        case .signedIn(let plan): .ready(BrowserAIAccount(plan: plan, usage: lastUsage))
        case .signedOut: .signedOut
        case .unreadable: .unavailable(.programNotResponding)
        }
        return BrowserAIProviderStatus(id: id, state: state, models: BrowserAIClaudeLaunch.models,
                                       programURL: location.url, version: location.version)
    }

    public func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        guard let location = await discovery.locate(.claude) else { return .failed(.notInstalled) }
        guard let directory = try? workspace.makeTurnDirectory() else { return .failed(.failed) }
        let arguments = BrowserAIClaudeLaunch.turnArguments(model: request.model, effort: request.effort,
                                                             instructions: request.instructions)
        lastArguments = arguments
        let process: BrowserAIProcess
        do {
            process = try BrowserAIProcess(BrowserAICommand(executable: location.url, arguments: arguments,
                environment: environment(location), workingDirectory: directory))
        } catch {
            workspace.remove(directory)
            return .failed(.failed)
        }
        running[ObjectIdentifier(process)] = process
        let (events, continuation) = AsyncStream.makeStream(of: BrowserAITurnEvent.self, bufferingPolicy: .unbounded)
        let sink = BrowserAITurnSink(continuation)
        let interrupted = BrowserAIFlag()
        let message = BrowserAIClaudeLaunch.userMessage(request.prompt).line()
        // A large prompt may fill the pipe: write it off the actor.
        Task.detached {
            process.write(message)
            process.closeInput()
        }
        Task { await self.read(process, sink: sink, interrupted: interrupted, directory: directory) }
        let grace = interruptGrace
        return BrowserAITurn(events: events) {
            guard !sink.isFinished else { return }
            interrupted.set()
            process.signal(SIGINT)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                if process.isRunning { await process.terminate(grace: 1) }
            }
        }
    }

    public func shutdown() async {
        let processes = running.values
        running = [:]
        for process in processes { await process.terminate(grace: 1) }
    }

    private func environment(_ location: BrowserAIProgramLocation) -> [String: String] {
        BrowserAIEnvironment.make(base: baseEnvironment, searchPath: location.searchPath)
    }

    private func read(_ process: BrowserAIProcess, sink: BrowserAITurnSink, interrupted: BrowserAIFlag, directory: URL) async {
        var succeeded = false
        var resultText: String?
        var assistantError: String?
        var turnUsage: BrowserAIUsage?
        var audit = BrowserAIClaudeTurnAudit()
        for await line in process.lines {
            guard let event = BrowserAIJSON.parse(line) else { continue }
            switch event["type"]?.string {
            case "system":
                if event["subtype"]?.string == "init" {
                    audit.toolsOffered = (event["tools"]?.array?.count ?? 0) + (event["mcp_servers"]?.array?.count ?? 0)
                }
            case "stream_event":
                let inner = event["event"]
                if inner?["type"]?.string == "content_block_delta", inner?["delta"]?["type"]?.string == "text_delta",
                   let text = inner?["delta"]?["text"]?.string, !text.isEmpty {
                    sink.yield(.text(text))
                }
            case "rate_limit_event":
                if let info = event["rate_limit_info"], let update = BrowserAIClaudeLaunch.usage(fromRateLimit: info) {
                    let merged = lastUsage?.merging(update) ?? update
                    lastUsage = merged
                    turnUsage = merged
                    sink.yield(.usage(merged))
                }
            case "assistant":
                if let error = event["error"]?.string { assistantError = error }
                audit.toolCalls += (event["message"]?["content"]?.array ?? []).filter {
                    ["tool_use", "server_tool_use", "mcp_tool_use"].contains($0["type"]?.string ?? "")
                }.count
            case "result":
                audit.permissionDenials = event["permission_denials"]?.array?.count ?? 0
                let isError = event["is_error"]?.bool ?? (event["subtype"]?.string != "success")
                succeeded = !isError && event["subtype"]?.string == "success"
                resultText = event["result"]?.string
            default: break
            }
        }
        _ = await process.waitForExit()
        lastAudit = audit
        running[ObjectIdentifier(process)] = nil
        workspace.remove(directory)
        if succeeded { sink.yield(.completed) }
        else if interrupted.value { sink.yield(.interrupted) }
        else {
            sink.yield(.failed(BrowserAIClaudeLaunch.error(resultText: resultText, assistantError: assistantError,
                                                           usage: turnUsage)))
        }
    }
}
