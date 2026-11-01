import AppKit
import BrowserCore
import Combine
import Foundation

/// The app's AI providers and their last known status. Nothing starts until Settings › AI
/// opens or the user turns AI on; programs are stopped again while AI stays off.
@MainActor
final class OrbitAIService: ObservableObject {
    @Published var statuses: [BrowserAIProviderID: BrowserAIProviderStatus] = [:]
    @Published private(set) var isChecking = false
    var clientOverrides: [BrowserAIProviderID: any BrowserAIProviderClient] = [:]
    let discovery: BrowserAIProgramDiscovery
    let workspace: BrowserAIWorkspace
    let codex: BrowserAICodexClient
    let claude: BrowserAIClaudeClient
    let onDevice = OrbitOnDeviceAIClient()
    private var refreshTask: Task<Void, Never>?

    /// Display order in Settings: programs first, then this Mac.
    static let order: [BrowserAIProviderID] = [.codex, .claudeCode, .onDevice]

    init(startsPrograms: Bool = true,
         version: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1") {
        let workspace = BrowserAIWorkspace()
        let parent = workspace.root.deletingLastPathComponent()
        // Inert providers look in an empty location and never run a shell.
        let discovery = startsPrograms
            ? BrowserAIProgramDiscovery(workingDirectory: parent)
            : BrowserAIProgramDiscovery(home: workspace.root.appendingPathComponent("no-home"), systemDirectories: [], shell: nil,
                                        workingDirectory: parent)
        self.workspace = workspace
        self.discovery = discovery
        codex = BrowserAICodexClient(discovery: discovery, workspace: workspace, clientVersion: version)
        claude = BrowserAIClaudeClient(discovery: discovery, workspace: workspace)
    }

    func client(_ id: BrowserAIProviderID) -> any BrowserAIProviderClient {
        if let override = clientOverrides[id] { return override }
        return switch id {
        case .codex: codex
        case .claudeCode: claude
        case .onDevice: onDevice
        }
    }

    /// Re-check every provider. `explicit` (Check Again) also repeats the login-shell lookup.
    /// While AI is off, the Codex process used for the status read is stopped afterwards.
    func refresh(explicit: Bool = false, keepRunning: Bool) {
        guard refreshTask == nil else { return }
        isChecking = true
        refreshTask = Task { [weak self, discovery, codex, claude, onDevice] in
            if explicit { await discovery.forgetShellLookup() }
            async let codexStatus = codex.status(refresh: true)
            async let claudeStatus = claude.status(refresh: true)
            async let deviceStatus = onDevice.status(refresh: true)
            let results = await [codexStatus, claudeStatus, deviceStatus]
            if !keepRunning { await codex.shutdown() }
            guard let self else { return }
            statuses = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
            isChecking = false
            refreshTask = nil
        }
    }

    /// AI turned off: stop every program now. Status stays displayed.
    func stopPrograms() {
        Task { [codex, claude] in
            await codex.shutdown()
            await claude.shutdown()
        }
    }

    /// Synchronous quit path: no program outlives Circa, and the private folder is removed.
    func terminateNow() {
        refreshTask?.cancel()
        BrowserAIProcess.terminateAll()
        workspace.removeAll()
    }
}
