import CoreGraphics
import Darwin
import Foundation

// Independent hidden-mode witness for the laboratory runner, outside the lab process:
// polls CGWindowList for on-screen windows owned by <root-pid> or any descendant (CEF helpers),
// appends one JSON line per sample with a finding to <out.jsonl>, and sends SIGTERM to the root
// (controlled shutdown in the lab), then SIGKILL if needed. Tracks the owned session group
// through leader exit, runner death and its independent deadline.
// Usage: OrbitWindowWatch <root-pid> <out.jsonl> [interval-ms]

func reject(_ code: Int32, _ reason: String, _ details: [String: Any] = [:]) -> Never {
    let record: [String: Any] = ["event": "witness-refused", "exit": code, "reason": reason,
                                 "argv": CommandLine.arguments, "details": details]
    if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
        FileHandle.standardError.write(data + Data("\n".utf8))
    }
    exit(code)
}
let arguments = CommandLine.arguments
guard arguments.count >= 3, let root = pid_t(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: OrbitWindowWatch <root-pid> <out.jsonl> [interval-ms]\n".utf8))
    reject(64, "invalid-arguments-or-identity")
}
var visibleMode = false
var visibleLimit: Int?
var capabilityPath: String?
var identityPath: String?
let interval = arguments.count > 3 ? max(20, Int(arguments[3]) ?? 100) : 100
var index = 4
while index < arguments.count {
    if arguments[index] == "--owned-process", index + 1 < arguments.count {
        identityPath = arguments[index + 1]; index += 2
    } else if arguments[index] == "--visible-owned-window", index + 2 < arguments.count {
        visibleMode = true; capabilityPath = arguments[index + 1]
        visibleLimit = Int(arguments[index + 2]); index += 3
    } else { reject(64, "invalid-arguments-or-identity") }
}
guard root > 1, let identityPath, let identityData = try? Data(contentsOf: URL(fileURLWithPath: identityPath)),
      let identity = try? JSONDecoder().decode(OwnedProcessIdentity.self, from: identityData), identity.pid == root,
      identity.runnerPID > 1, (1...360).contains(identity.maximumSeconds),
      !visibleMode || (15...90).contains(visibleLimit ?? 0) else { reject(64, "invalid-arguments-or-identity") }
let supervisor = OwnedSessionSupervisor(identity: identity)
// Cancellation of the launcher must not interrupt the independent escalation deadline.
for signalNumber in [SIGTERM, SIGINT, SIGHUP] { signal(signalNumber, SIG_IGN) }
FileManager.default.createFile(atPath: arguments[2], contents: nil, attributes: [.posixPermissions: 0o600])
guard let out = FileHandle(forWritingAtPath: arguments[2]) else {
    try? supervisor.send(SIGTERM)
    usleep(1_000_000)
    try? supervisor.send(SIGKILL)
    reject(73, "evidence-output-unavailable")
}

func write(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
        out.write(data + Data("\n".utf8))
    }
}

supervisor.onObservation = { write($0) }
write(["event": "witness-admitted", "argv": arguments, "expectedPID": identity.pid,
       "expectedExecutable": identity.executable, "expectedApplication": identity.application,
       "observedAtLaunch": identity.observedAtLaunch?.evidence as Any? ?? NSNull()])
let start = Date()
var samples = 0, onScreenSamples = 0, maxTree = 0
var signalled = false
var unexpectedSamples = 0, maxVisibleWindows = 0, durationExceeded = false
var visibleAcknowledged = false
var termination = OwnedTerminationSchedule()
var forcedKill = false
var remainingOwned = 0
while true {
    let members: [pid_t]
    do { members = try supervisor.liveMembers() }
    catch let failure as OwnedSessionSupervisor.Failure {
        write(["event": "ownership-refused", "details": failure.evidence])
        reject(74, failure.reason, failure.evidence)
    } catch { reject(74, "unexpected-identity-error", ["type": String(describing: error)]) }
    if members.isEmpty { break }
    let tree = Set(members)
    maxTree = max(maxTree, tree.count)
    samples += 1
    let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? NSNumber).map { tree.contains(pid_t($0.int32Value)) } ?? false }
    maxVisibleWindows = max(maxVisibleWindows, windows.count)
    var unexpected = !windows.isEmpty
    if visibleMode {
        // The fresh synthetic root carries only the exact window created by this host.
        let capability = (try? Data(contentsOf: URL(fileURLWithPath: capabilityPath!)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let owned = windows.map { row in
            ["owner": (row[kCGWindowOwnerPID as String] as? Int) ?? -1,
             "number": (row[kCGWindowNumber as String] as? Int) ?? -1]
        }
        unexpected = WindowWitnessPolicy.unexpected(windows: owned, root: Int(root), capability: capability)
        if !unexpected && !windows.isEmpty && !visibleAcknowledged, let capability,
           let data = try? JSONSerialization.data(withJSONObject: capability, options: [.sortedKeys]) {
            let acknowledgement = URL(fileURLWithPath: capabilityPath!).deletingLastPathComponent()
                .appendingPathComponent("visible-window-observed.json")
            do {
                try data.write(to: acknowledgement, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: acknowledgement.path)
                visibleAcknowledged = true
            } catch { unexpected = true }
        }
    }
    if unexpected { unexpectedSamples += 1 }
    if !windows.isEmpty {
        onScreenSamples += 1
        write(["event": "on-screen", "t": Date().timeIntervalSince(start), "count": windows.count,
               "owners": windows.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue },
               "unexpected": unexpected, "windowNumbers": windows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue },
               "layers": windows.compactMap { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue }])
    }
    let elapsed = Date().timeIntervalSince(start)
    durationExceeded = elapsed > (visibleMode ? Double(visibleLimit!) : identity.maximumSeconds)
    let runnerGone = kill(identity.runnerPID, 0) != 0
    if let signal = termination.signal(now: elapsed, requested: unexpected || durationExceeded || runnerGone) {
        signalled = true
        forcedKill = forcedKill || signal == SIGKILL
        try? supervisor.send(signal)
    }
    if let termAt = termination.termAt, elapsed >= termAt + 4 {
        remainingOwned = (try? supervisor.liveMembers().count) ?? -1
        break
    }
    usleep(useconds_t(interval * 1000))
}
write(["event": "summary", "samples": samples, "onScreenSamples": onScreenSamples, "maxProcessTree": maxTree,
       "intervalMs": interval, "signalledRoot": signalled,
       "forcedKill": forcedKill, "remainingOwnedProcesses": remainingOwned,
       "mode": visibleMode ? "visible-input" : "hidden", "unexpectedOnScreenSamples": unexpectedSamples,
       "maxVisibleWindows": maxVisibleWindows, "durationExceeded": durationExceeded, "seconds": Date().timeIntervalSince(start)])
exit(0)
