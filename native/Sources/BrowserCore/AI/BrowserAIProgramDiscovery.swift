import Darwin
import Foundation

/// The command-line programs Circa can drive.
public enum BrowserAIProgram: String, CaseIterable, Sendable {
    case codex
    case claude

    public var executableName: String { rawValue }

    /// The program's own `--version` output identifies it; anything else on the path is refused.
    public func version(from output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let pattern = switch self {
        case .codex: #"^codex-cli ([0-9][0-9A-Za-z.\-+]*)\s*$"#
        case .claude: #"^([0-9][0-9A-Za-z.\-+]*) \(Claude Code\)\s*$"#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    /// Official install pages, shown when the program is missing.
    public var installPage: URL {
        switch self {
        case .codex: URL(string: "https://developers.openai.com/codex")!
        case .claude: URL(string: "https://claude.com/claude-code")!
        }
    }
}

public struct BrowserAIProgramLocation: Equatable, Sendable {
    public var program: BrowserAIProgram
    public var url: URL
    public var version: String
    /// Directories for the child's PATH (an npm install needs `node` beside it).
    public var searchPath: [String]
}

/// Finds an installed program by absolute path. Known install locations come first, then one
/// login-shell `command -v` lookup, cached until the next explicit check. The app's own PATH is
/// never used: Finder launches with a minimal one.
public actor BrowserAIProgramDiscovery {
    public struct ShellLookup: Equatable, Sendable {
        public var paths: [BrowserAIProgram: String]
        public var searchPath: [String]
    }

    private let home: URL
    private let systemDirectories: [String]
    private let shell: URL?
    private let baseEnvironment: [String: String]
    private let workingDirectory: URL
    private let versionTimeout: TimeInterval
    private let shellTimeout: TimeInterval
    private var shellLookup: ShellLookup??
    private var located: [BrowserAIProgram: BrowserAIProgramLocation] = [:]
    public private(set) var shellLookupCount = 0

    public static let defaultSystemDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                systemDirectories: [String] = BrowserAIProgramDiscovery.defaultSystemDirectories,
                shell: URL? = BrowserAIProgramDiscovery.loginShell(),
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                workingDirectory: URL = FileManager.default.temporaryDirectory,
                versionTimeout: TimeInterval = 8, shellTimeout: TimeInterval = 5) {
        self.home = home
        self.systemDirectories = systemDirectories
        self.shell = shell
        self.baseEnvironment = baseEnvironment
        self.workingDirectory = workingDirectory
        self.versionTimeout = versionTimeout
        self.shellTimeout = shellTimeout
    }

    /// The verified location, or nil when the program is not on this Mac. `refresh` verifies the
    /// program again; the shell lookup stays cached until `forgetShellLookup()`.
    public func locate(_ program: BrowserAIProgram, refresh: Bool = false) async -> BrowserAIProgramLocation? {
        if refresh {
            located[program] = nil
        } else if let cached = located[program], FileManager.default.isExecutableFile(atPath: cached.url.path) {
            return cached
        }
        for candidate in Self.knownLocations(for: program, home: home, systemDirectories: systemDirectories) {
            if let location = await verify(program, at: candidate, extraPath: []) {
                located[program] = location
                return location
            }
        }
        let lookup = await lookupInLoginShell()
        if let path = lookup?.paths[program], path.hasPrefix("/"),
           let location = await verify(program, at: URL(fileURLWithPath: path), extraPath: lookup?.searchPath ?? []) {
            located[program] = location
            return location
        }
        located[program] = nil
        return nil
    }

    /// An explicit "Check Again" also repeats the login-shell lookup (a program may just have been
    /// installed in a directory only the shell knows).
    public func forgetShellLookup() { shellLookup = nil }

    /// Known install locations, most specific first. nvm installs are listed newest first.
    public static func knownLocations(for program: BrowserAIProgram, home: URL,
                                      systemDirectories: [String] = defaultSystemDirectories) -> [URL] {
        let name = program.executableName
        var directories = [home.appendingPathComponent(".local/bin").path] + systemDirectories + [
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent(".volta/bin").path,
        ]
        if program == .claude { directories.insert(home.appendingPathComponent(".claude/local").path, at: 1) }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
        for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            directories.append(nvm.appendingPathComponent(version).appendingPathComponent("bin").path)
        }
        return directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The user's login shell from the account database, limited to POSIX-compatible shells.
    public static func loginShell() -> URL? {
        guard let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell else { return URL(fileURLWithPath: "/bin/zsh") }
        let path = String(cString: raw)
        let accepted = ["zsh", "bash", "sh", "dash", "ksh"]
        guard path.hasPrefix("/"), accepted.contains(URL(fileURLWithPath: path).lastPathComponent),
              FileManager.default.isExecutableFile(atPath: path) else { return URL(fileURLWithPath: "/bin/zsh") }
        return URL(fileURLWithPath: path)
    }

    static let shellScript = #"printf 'codex=%s\nclaude=%s\npath=%s\n' "$(command -v codex)" "$(command -v claude)" "$PATH""#

    private func lookupInLoginShell() async -> ShellLookup? {
        if let cached = shellLookup { return cached }
        guard let shell else { shellLookup = .some(nil); return nil }
        shellLookupCount += 1
        var environment = BrowserAIEnvironment.make(base: [:], searchPath: [])
        for key in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"] { environment[key] = baseEnvironment[key] }
        environment["HOME"] = home.path
        environment["SHELL"] = shell.path
        let result = await BrowserAIProcess.run(BrowserAICommand(executable: shell, arguments: ["-l", "-c", Self.shellScript],
            environment: environment, workingDirectory: workingDirectory), timeout: shellTimeout, outputLimit: 64 << 10)
        var paths: [BrowserAIProgram: String] = [:]
        var searchPath: [String] = []
        // Profiles may print banners: only the marked lines are read.
        for line in result.text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "codex": if parts[1].hasPrefix("/") { paths[.codex] = parts[1] }
            case "claude": if parts[1].hasPrefix("/") { paths[.claude] = parts[1] }
            case "path": searchPath = parts[1].split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
            default: continue
            }
        }
        let lookup = result.timedOut ? nil : ShellLookup(paths: paths, searchPath: searchPath)
        shellLookup = .some(lookup)
        return lookup
    }

    private func verify(_ program: BrowserAIProgram, at url: URL, extraPath: [String]) async -> BrowserAIProgramLocation? {
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: resolved.path) else { return nil }
        let searchPath = Self.unique([url.deletingLastPathComponent().path, resolved.deletingLastPathComponent().path]
            + extraPath + systemDirectories)
        let command = BrowserAICommand(executable: url, arguments: ["--version"],
            environment: BrowserAIEnvironment.make(base: baseEnvironment, searchPath: searchPath),
            workingDirectory: workingDirectory)
        let result = await BrowserAIProcess.run(command, timeout: versionTimeout, outputLimit: 16 << 10)
        guard result.status == 0, let version = program.version(from: result.text) else { return nil }
        return BrowserAIProgramLocation(program: program, url: url, version: version, searchPath: searchPath)
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
