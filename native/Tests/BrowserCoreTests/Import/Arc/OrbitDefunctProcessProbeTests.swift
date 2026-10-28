import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("Offline import ignores exited browser processes")
struct OrbitDefunctProcessProbeTests {
    @Test func realZombieDoesNotBlockAnUnrelatedTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-process-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("Orbit")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let argument = try #require(strdup(executable.path))
        defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        var child: pid_t = 0
        let status = arguments.withUnsafeMutableBufferPointer {
            posix_spawn(&child, executable.path, nil, nil, $0.baseAddress!, nil)
        }
        try #require(status == 0)
        defer { var status: Int32 = 0; _ = waitpid(child, &status, 0) }
        // Observe exit without reaping it: this is a real kernel zombie, not a process double.
        var information = siginfo_t()
        try #require(waitid(P_PID, id_t(child), &information, WEXITED | WNOWAIT) == 0)
        let processes = try #require(ArcProcessList.processes())
        #expect(!processes.contains { $0.pid == child })
        #expect(!ArcSystemRunningProbe().isInUse(sessionFile: root.appendingPathComponent("target/session.json")))
    }
}
