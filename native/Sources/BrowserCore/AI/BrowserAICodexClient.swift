import Foundation

/// How Circa starts `codex app-server`. Page content sent by later features is untrusted, so the
/// program runs with no local tools: no shell, no file edits, no web search, no MCP servers,
/// plugins, hooks, project instructions, notify program or history, in a read-only sandbox.
/// The keys were checked with `config/read` on codex-cli 0.165.0.
public enum BrowserAICodexLaunch {
    public static let baseOverrides: [String] = [
        #"sandbox_mode="read-only""#,
        #"approval_policy="on-request""#,
        #"web_search="disabled""#,
        "tools.view_image=false",
        "features.shell_tool=false",
        "features.unified_exec=false",
        "features.shell_snapshot=false",
        "features.js_repl=false",
        "features.view_image=false",
        "features.apps=false",
        "features.plugins=false",
        "features.remote_plugin=false",
        "features.browser_use=false",
        "features.browser_use_external=false",
        "features.computer_use=false",
        "features.in_app_browser=false",
        "features.in_app_local_automation=false",
        "features.image_generation=false",
        "features.multi_agent=false",
        "features.hooks=false",
        "features.memories=false",
        "features.skill_search=false",
        "features.tool_suggest=false",
        "features.goals=false",
        "features.workspace_dependencies=false",
        "notify=[]",
        "project_doc_max_bytes=0",
        #"history.persistence="none""#,
        "include_environment_context=false",
        "include_permissions_instructions=false",
        "include_apps_instructions=false",
        "allow_login_shell=false",
        "check_for_update_on_startup=false",
    ]

    /// Names the program reads as one dotted-path segment. Anything else cannot be switched off
    /// reliably, and Circa then refuses to use the program.
    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "_-@".unicodeScalars.contains($0)
        }
    }

    /// `codex app-server` arguments. User-configured MCP servers and plugins are switched off by
    /// name: an empty-table override is merged with the user's config and does not remove them.
    public static func arguments(disablingMCPServers servers: [String] = [], plugins: [String] = []) -> [String] {
        var overrides = baseOverrides
        overrides += servers.sorted().map { "mcp_servers.\($0).enabled=false" }
        overrides += plugins.sorted().map { "plugins.\($0).enabled=false" }
        return ["app-server"] + overrides.flatMap { ["-c", $0] }
    }

    public static func initializeParams(version: String) -> BrowserAIJSON {
        ["clientInfo": ["name": "circa", "title": "Circa", "version": .string(version)]]
    }

    /// One ephemeral thread per conversation, in an empty private directory.
    public static func threadStartParams(directory: URL, instructions: String, model: String?) -> BrowserAIJSON {
        var params: [String: BrowserAIJSON] = [
            "cwd": .string(directory.path),
            "sandbox": "read-only",
            "approvalPolicy": "on-request",
            "ephemeral": true,
            "developerInstructions": .string(instructions),
        ]
        if let model { params["model"] = .string(model) }
        return .object(params)
    }

    public static func turnStartParams(threadID: String, prompt: String, model: String?, effort: String?) -> BrowserAIJSON {
        var params: [String: BrowserAIJSON] = [
            "threadId": .string(threadID),
            "input": [["type": "text", "text": .string(prompt)]],
        ]
        if let model { params["model"] = .string(model) }
        if let effort { params["effort"] = .string(effort) }
        return .object(params)
    }

    /// Circa answers every request the program sends: approvals are declined and tool calls fail.
    /// Returns the JSON-RPC result, or nil for an error reply.
    public static func reply(toServerRequest method: String) -> BrowserAIJSON? {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval": ["decision": "decline"]
        case "execCommandApproval", "applyPatchApproval": ["decision": "denied"]
        case "item/permissions/requestApproval": ["permissions": [:], "scope": "turn"]
        case "mcpServer/elicitation/request": ["action": "decline"]
        case "item/tool/requestUserInput": ["answers": [:]]
        case "item/tool/call": ["contentItems": [], "success": false]
        default: nil
        }
    }

    /// The effective config must show every tool switched off before a turn may start.
    public static func lockdownViolations(in config: BrowserAIJSON) -> [String] {
        var violations: [String] = []
        if config["sandbox_mode"]?.string != "read-only" { violations.append("sandbox_mode") }
        if config["web_search"]?.string != "disabled" { violations.append("web_search") }
        let features = config["features"]
        if features?["shell_tool"]?.bool != false { violations.append("features.shell_tool") }
        for key in ["plugins", "apps"] {
            if let value = features?[key], value.bool != false { violations.append("features." + key) }
        }
        if let notify = config["notify"], !(notify.isNull || notify.array?.isEmpty == true) { violations.append("notify") }
        if config["project_doc_max_bytes"]?.int != 0 { violations.append("project_doc_max_bytes") }
        let (servers, plugins) = enabledExtensions(in: config)
        violations += servers.map { "mcp_servers." + $0 } + plugins.map { "plugins." + $0 }
        return violations
    }

    /// MCP servers and plugins the user's config enables.
    public static func enabledExtensions(in config: BrowserAIJSON) -> (servers: [String], plugins: [String]) {
        func enabled(_ table: BrowserAIJSON?) -> [String] {
            (table?.object ?? [:]).filter { $0.value["enabled"]?.bool != false }.map(\.key).sorted()
        }
        return (enabled(config["mcp_servers"]), enabled(config["plugins"]))
    }

    static func usage(fromRateLimits result: BrowserAIJSON) -> BrowserAIUsage? {
        guard let snapshot = result["rateLimitsByLimitId"]?["codex"] ?? result["rateLimits"],
              var usage = usage(fromSnapshot: snapshot) else { return nil }
        if result["ordinaryUsageAllowed"]?.bool == false {
            usage = BrowserAIUsage(windows: usage.windows, limitReached: true, limitResetsAt: usage.limitResetsAt
                ?? usage.windows.compactMap(\.resetsAt).max())
        }
        return usage
    }

    static func usage(fromSnapshot snapshot: BrowserAIJSON) -> BrowserAIUsage? {
        let windows = ["primary", "secondary"].compactMap { key -> BrowserAIUsageWindow? in
            guard let window = snapshot[key], let used = window["usedPercent"]?.double else { return nil }
            return BrowserAIUsageWindow(span: .init(minutes: window["windowDurationMins"]?.int), usedPercent: Int(used.rounded()),
                                        resetsAt: window["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0) })
        }.sorted { $0.span.order < $1.span.order }
        guard !windows.isEmpty else { return nil }
        let reached = snapshot["rateLimitReachedType"]?.string != nil
        return BrowserAIUsage(windows: windows, limitReached: reached,
                              limitResetsAt: reached ? windows.compactMap(\.resetsAt).max() : nil)
    }

    static func models(from result: BrowserAIJSON) -> [BrowserAIModel] {
        (result["data"]?.array ?? []).compactMap { entry in
            guard entry["hidden"]?.bool != true, let model = entry["model"]?.string ?? entry["id"]?.string else { return nil }
            return BrowserAIModel(provider: .codex, id: model, displayName: entry["displayName"]?.string ?? model,
                efforts: (entry["supportedReasoningEfforts"]?.array ?? []).compactMap { $0["reasoningEffort"]?.string },
                defaultEffort: entry["defaultReasoningEffort"]?.string, isDefault: entry["isDefault"]?.bool ?? false)
        }
    }

    static func error(from turnError: BrowserAIJSON?, usage: BrowserAIUsage?) -> BrowserAIError {
        switch turnError?["codexErrorInfo"]?.string {
        case "usageLimitExceeded": .limitReached(resetsAt: usage?.limitResetsAt)
        case "unauthorized": .signedOut
        default: .failed
        }
    }
}

struct BrowserAICodexRPCError: Error, Equatable {
    var code: Int
    static let closed = BrowserAICodexRPCError(code: -1)
    static let timedOut = BrowserAICodexRPCError(code: -2)
    static let unwritable = BrowserAICodexRPCError(code: -3)
}

/// One `codex app-server` process speaking newline-delimited JSON-RPC over stdio.
actor BrowserAICodexConnection {
    typealias NotificationHandler = @Sendable (String, BrowserAIJSON) async -> Void
    let process: BrowserAIProcess
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<BrowserAIJSON, Error>] = [:]
    private var notificationHandler: NotificationHandler?
    private var closeHandler: (@Sendable () async -> Void)?
    private(set) var isOpen = true
    /// Methods of the requests Circa declined, in order (tests and diagnostics; no parameters).
    private(set) var declinedRequests: [String] = []

    init(command: BrowserAICommand) throws { process = try BrowserAIProcess(command) }

    func start(onNotification: @escaping NotificationHandler, onClose: @escaping @Sendable () async -> Void) {
        notificationHandler = onNotification
        closeHandler = onClose
        Task { [process] in
            for await line in process.lines { await self.handle(line) }
            _ = await process.waitForExit()
            await self.closed()
        }
    }

    func request(_ method: String, _ params: BrowserAIJSON = [:], timeout: TimeInterval) async throws -> BrowserAIJSON {
        guard isOpen else { throw BrowserAICodexRPCError.closed }
        nextID += 1
        let id = nextID
        let message: BrowserAIJSON = ["id": .number(Double(id)), "method": .string(method), "params": params]
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.fail(id, BrowserAICodexRPCError.timedOut)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            if !process.write(message.line()) { fail(id, BrowserAICodexRPCError.unwritable) }
        }
    }

    func notify(_ method: String, _ params: BrowserAIJSON? = nil) {
        var message: [String: BrowserAIJSON] = ["method": .string(method)]
        if let params { message["params"] = params }
        process.write(BrowserAIJSON.object(message).line())
    }

    func shutdown() async {
        isOpen = false
        await process.terminate(grace: 1)
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func handle(_ line: Data) async {
        guard let message = BrowserAIJSON.parse(line), message.object != nil else { return }
        let method = message["method"]?.string
        if let id = message["id"], !id.isNull, let method {
            // A request from the program: never approve anything.
            declinedRequests.append(method)
            let reply: BrowserAIJSON
            if let result = BrowserAICodexLaunch.reply(toServerRequest: method) { reply = ["id": id, "result": result] }
            else { reply = ["id": id, "error": ["code": -32601, "message": "Not supported by Circa"]] }
            process.write(reply.line())
        } else if let id = message["id"]?.int {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = message["error"], !error.isNull {
                continuation.resume(throwing: BrowserAICodexRPCError(code: error["code"]?.int ?? 0))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
        } else if let method {
            await notificationHandler?(method, message["params"] ?? .null)
        }
    }

    private func closed() async {
        isOpen = false
        for continuation in pending.values { continuation.resume(throwing: BrowserAICodexRPCError.closed) }
        pending = [:]
        let handler = closeHandler
        closeHandler = nil
        await handler?()
    }
}

/// Codex through the user's own `codex app-server` and its existing sign-in. Circa reads only
/// the plan type from `account/read`: never the email or account ids.
public actor BrowserAICodexClient: BrowserAIProviderClient {
    public nonisolated let id = BrowserAIProviderID.codex
    private let discovery: BrowserAIProgramDiscovery
    private let workspace: BrowserAIWorkspace
    private let baseEnvironment: [String: String]
    private let clientVersion: String
    private let requestTimeout: TimeInterval
    private var connection: BrowserAICodexConnection?
    private var connecting: Task<BrowserAICodexConnection, Error>?
    private var disabledServers: [String] = []
    private var disabledPlugins: [String] = []
    private var routes: [String: Route] = [:]
    private var crashes: [Date] = []
    private var lastUsage: BrowserAIUsage?
    private var lastModels: [BrowserAIModel] = []
    /// Process launches, including lockdown relaunches (tests).
    public private(set) var launches = 0
    public private(set) var lastArguments: [String] = []

    private final class Route: @unchecked Sendable {
        let sink: BrowserAITurnSink
        let directory: URL
        var turnID: String?
        var interruptRequested = false
        var error: BrowserAIJSON?
        init(sink: BrowserAITurnSink, directory: URL) { self.sink = sink; self.directory = directory }
    }

    public init(discovery: BrowserAIProgramDiscovery, workspace: BrowserAIWorkspace,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                clientVersion: String = "1", requestTimeout: TimeInterval = 20) {
        self.discovery = discovery
        self.workspace = workspace
        self.baseEnvironment = baseEnvironment
        self.clientVersion = clientVersion
        self.requestTimeout = requestTimeout
    }

    public func status(refresh: Bool) async -> BrowserAIProviderStatus {
        if refresh { crashes = [] }
        guard let location = await discovery.locate(.codex, refresh: refresh) else {
            await shutdown()
            return BrowserAIProviderStatus(id: id, state: .notInstalled)
        }
        func status(_ state: BrowserAIProviderState, models: [BrowserAIModel] = []) -> BrowserAIProviderStatus {
            BrowserAIProviderStatus(id: id, state: state, models: models, programURL: location.url, version: location.version)
        }
        do {
            let connection = try await ensureConnection()
            let account = try await connection.request("account/read", [:], timeout: requestTimeout)
            guard let details = account["account"], details.object != nil else {
                return status(account["requiresOpenaiAuth"]?.bool == false ? .ready(.init(plan: nil)) : .signedOut)
            }
            let plan = details["type"]?.string == "chatgpt" ? details["planType"]?.string : details["type"]?.string
            if let limits = try? await connection.request("account/rateLimits/read", [:], timeout: requestTimeout) {
                lastUsage = BrowserAICodexLaunch.usage(fromRateLimits: limits)
            }
            if let list = try? await connection.request("model/list", [:], timeout: requestTimeout) {
                lastModels = BrowserAICodexLaunch.models(from: list)
            }
            return status(.ready(.init(plan: plan, usage: lastUsage)), models: lastModels)
        } catch let error as BrowserAIError {
            switch error {
            case .notInstalled: return BrowserAIProviderStatus(id: id, state: .notInstalled)
            case .unavailable(let reason): return status(.unavailable(reason))
            case .signedOut: return status(.signedOut)
            default: return status(.unavailable(.programNotResponding))
            }
        } catch {
            return status(.unavailable(.programNotResponding))
        }
    }

    public func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        let (events, continuation) = AsyncStream.makeStream(of: BrowserAITurnEvent.self, bufferingPolicy: .unbounded)
        let sink = BrowserAITurnSink(continuation)
        let threadID: String
        let route: Route
        do {
            let connection = try await ensureConnection()
            let directory = try workspace.makeTurnDirectory()
            let thread = try await connection.request("thread/start", BrowserAICodexLaunch.threadStartParams(
                directory: directory, instructions: request.instructions, model: request.model), timeout: requestTimeout)
            guard let id = thread["thread"]?["id"]?.string else { workspace.remove(directory); throw BrowserAIError.failed }
            threadID = id
            route = Route(sink: sink, directory: directory)
            routes[threadID] = route
            let started = try await connection.request("turn/start", BrowserAICodexLaunch.turnStartParams(
                threadID: threadID, prompt: request.prompt, model: request.model, effort: request.effort), timeout: requestTimeout)
            if route.turnID == nil { route.turnID = started["turn"]?["id"]?.string }
            if route.interruptRequested { Task { await self.sendInterrupt(threadID) } }
        } catch let error as BrowserAIError {
            sink.yield(.failed(error))
            return BrowserAITurn(events: events, interrupt: {})
        } catch {
            let state = await status(refresh: false).state
            sink.yield(.failed(state == .signedOut ? .signedOut : .failed))
            return BrowserAITurn(events: events, interrupt: {})
        }
        return BrowserAITurn(events: events, interrupt: { [weak self] in await self?.interrupt(threadID) })
    }

    public func shutdown() async {
        connecting?.cancel()
        connecting = nil
        guard let current = connection else { return }
        connection = nil
        for (thread, route) in routes { finish(thread, route, .interrupted) }
        await current.shutdown()
    }

    // MARK: Connection

    private func ensureConnection() async throws -> BrowserAICodexConnection {
        if let connection, await connection.isOpen { return connection }
        if let connecting { return try await connecting.value }
        crashes = crashes.filter { $0.timeIntervalSinceNow > -60 }
        guard crashes.count < 3 else { throw BrowserAIError.unavailable(.programNotResponding) }
        let task = Task { try await self.launchLockedDown() }
        connecting = task
        defer { connecting = nil }
        let opened = try await task.value
        connection = opened
        return opened
    }

    private func launchLockedDown() async throws -> BrowserAICodexConnection {
        guard let location = await discovery.locate(.codex) else { throw BrowserAIError.notInstalled }
        let root = try workspace.rootDirectory()
        for _ in 0..<2 {
            let connection = try await launch(location, root: root)
            let config = try await connection.request("config/read", ["includeLayers": false], timeout: requestTimeout)["config"] ?? .null
            let violations = BrowserAICodexLaunch.lockdownViolations(in: config)
            if violations.isEmpty { return connection }
            await connection.shutdown()
            let (servers, plugins) = BrowserAICodexLaunch.enabledExtensions(in: config)
            let newServers = servers.filter { !disabledServers.contains($0) }, newPlugins = plugins.filter { !disabledPlugins.contains($0) }
            guard !(newServers + newPlugins).isEmpty, (newServers + newPlugins).allSatisfy(BrowserAICodexLaunch.isSafeName) else { break }
            disabledServers += newServers
            disabledPlugins += newPlugins
        }
        throw BrowserAIError.unavailable(.toolsNotDisabled)
    }

    private func launch(_ location: BrowserAIProgramLocation, root: URL) async throws -> BrowserAICodexConnection {
        let arguments = BrowserAICodexLaunch.arguments(disablingMCPServers: disabledServers, plugins: disabledPlugins)
        lastArguments = arguments
        launches += 1
        let connection = try BrowserAICodexConnection(command: BrowserAICommand(executable: location.url, arguments: arguments,
            environment: BrowserAIEnvironment.make(base: baseEnvironment, searchPath: location.searchPath), workingDirectory: root))
        await connection.start(onNotification: { [weak self] method, params in
            await self?.received(method, params)
        }, onClose: { [weak self, weak connection] in
            await self?.closed(connection)
        })
        do {
            _ = try await connection.request("initialize", BrowserAICodexLaunch.initializeParams(version: clientVersion), timeout: requestTimeout)
            await connection.notify("initialized")
        } catch {
            await connection.shutdown()
            throw error
        }
        return connection
    }

    private func closed(_ closing: BrowserAICodexConnection?) {
        guard let closing, closing === connection else { return }
        // A crash: fail the running turns. The next call starts a new process.
        connection = nil
        crashes.append(Date())
        for (thread, route) in routes { finish(thread, route, .failed(.failed)) }
    }

    // MARK: Turns

    private func received(_ method: String, _ params: BrowserAIJSON) async {
        if method == "account/rateLimits/updated", let snapshot = params["rateLimits"],
           let update = BrowserAICodexLaunch.usage(fromSnapshot: snapshot) {
            lastUsage = lastUsage?.merging(update) ?? update
            for route in routes.values { route.sink.yield(.usage(lastUsage ?? update)) }
            return
        }
        guard let thread = params["threadId"]?.string, let route = routes[thread] else { return }
        switch method {
        case "turn/started":
            if route.turnID == nil { route.turnID = params["turn"]?["id"]?.string }
        case "item/agentMessage/delta":
            if let delta = params["delta"]?.string, !delta.isEmpty { route.sink.yield(.text(delta)) }
        case "error":
            if params["willRetry"]?.bool != true { route.error = params["error"] }
        case "turn/completed":
            let turn = params["turn"]
            switch turn?["status"]?.string {
            case "completed": finish(thread, route, .completed)
            case "interrupted": finish(thread, route, .interrupted)
            default:
                let detail = turn?["error"].flatMap { $0.isNull ? nil : $0 } ?? route.error
                let error = BrowserAICodexLaunch.error(from: detail, usage: lastUsage)
                if case .limitReached(nil) = error {
                    // Read the reset time outside the notification loop, which must keep reading.
                    Task { await self.finishWithLimit(thread) }
                } else {
                    finish(thread, route, .failed(error))
                }
            }
        default: break
        }
    }

    private func finishWithLimit(_ thread: String) async {
        if let connection, let limits = try? await connection.request("account/rateLimits/read", [:], timeout: 5) {
            lastUsage = BrowserAICodexLaunch.usage(fromRateLimits: limits) ?? lastUsage
        }
        if let route = routes[thread] { finish(thread, route, .failed(.limitReached(resetsAt: lastUsage?.limitResetsAt))) }
    }

    private func finish(_ thread: String, _ route: Route, _ event: BrowserAITurnEvent) {
        routes[thread] = nil
        route.sink.yield(event)
        workspace.remove(route.directory)
    }

    private func interrupt(_ thread: String) async {
        guard let route = routes[thread] else { return }
        route.interruptRequested = true
        guard route.turnID != nil else { return }
        await sendInterrupt(thread)
    }

    private func sendInterrupt(_ thread: String) async {
        guard let route = routes[thread], let turn = route.turnID, let connection else { return }
        _ = try? await connection.request("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)], timeout: 5)
        // The program confirms with turn/completed (interrupted). If it does not, stop waiting.
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.abandon(thread, route)
        }
    }

    private func abandon(_ thread: String, _ route: Route) {
        if routes[thread] === route { finish(thread, route, .interrupted) }
    }

    /// Requests the program sent and Circa declined (tests).
    public func declinedRequests() async -> [String] { await connection?.declinedRequests ?? [] }
}
