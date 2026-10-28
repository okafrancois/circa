#!/usr/bin/env python3
"""Independent launcher/session-lock regression; inert runtime, private roots, no SecItem.

Reuse only private modules built by run_auth_registration_launcher_tests.py --compare-old.
The old preparation/launcher blobs and complete old BrowserCore hashes are checked first.
Exit 1 means the new launcher still prevents its own persistent-session shared lock.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--modules", type=Path, required=True)
parser.add_argument("--baseline", type=Path, required=True)
parser.add_argument("--scratch", type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
scratch = args.scratch.resolve()
scratch.mkdir(parents=True, exist_ok=False)
baseline = args.baseline.resolve()
old = "f874e602cf383f66bb589d09c9124009067edbef"
previous = json.loads((baseline / "results.json").read_text())
assert previous["oldRevision"] == old
for path, expected in previous["exactOldCoreSourceSHA256"].items():
    assert hashlib.sha256(subprocess.check_output(["git", "show", old + ":" + path], cwd=repo)).hexdigest() == expected

double = scratch / "SessionLockRuntime.swift"
double.write_text('''import AppKit
import BrowserCore
import Foundation
struct BrowserEnvironment<Engine> {}
struct BrowserWindowController<Engine> {}
struct ChromiumBrowserEngine {
    enum Persistence { case persistent, ephemeral }
    init(persistence: Persistence, hostedWhenAvailable: Bool) {}
}
enum OrbitStableSigning { static let rootSHA1 = "" }
struct ReviewRuntimeOptions { let root: URL }
@MainActor final class ChromiumRuntime {
    static let shared = ChromiumRuntime()
    func run(options: ReviewRuntimeOptions, ready: () -> Void) -> Int32 {
        // This is BrowserEnvironment.open's actual lock operation, without an engine/app.
        do {
            let reader = try OrbitDataDirectoryLock.acquire(options.root, exclusive: false, validatingPath: false)
            reader.release()
            print("session-read-lock-admitted")
        } catch {
            guard (error as? ArcImportError) == .targetInUse else { return 71 }
            print("session-read-lock-refused")
        }
        return 0
    }
}
@MainActor func productRuntimeOptions(_ configuration: OrbitProductConfiguration, extraSwitches: [String], hiddenApplication: Bool) -> ReviewRuntimeOptions {
    ReviewRuntimeOptions(root: configuration.dataRoot)
}
@MainActor func orbitLaunchHooks() -> (any OrbitLaunchHooks)? { nil }
@MainActor final class ColdLaunchOpenQueue {
    static let shared = ColdLaunchOpenQueue()
    func install() {}
    func deliver(to: OrbitApplication, application: NSApplication) { fatalError("No delivery permitted") }
}
@MainActor final class OrbitApplication: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { fatalError("No application permitted") }
}
@main struct SessionLockReview {
    @MainActor static func main() { OrbitLauncher.run() }
}
''')
sources = [repo / "native/Sources/Orbit/Environment" / name for name in
           ["OrbitBuildIdentity.swift", "OrbitProductConfiguration.swift", "SyntheticDataGuard.swift", "LaunchConfiguration.swift"]]
sources += [repo / "native/OrbitChromium/App/EngineComposition+Chromium.swift"]
results = []
for revision in ["old", "reviewed"]:
    selected = sources
    modules = args.modules.resolve()
    if revision == "old":
        selected = [baseline / "old" / source.name for source in sources]
        for source, extracted in zip(sources, selected):
            assert extracted.read_bytes() == subprocess.check_output(["git", "show", old + ":" + str(source.relative_to(repo))], cwd=repo)
        modules = baseline / "old-modules"
    executable = scratch / revision
    command = ["swiftc", "-swift-version", "6", "-j", "2", "-num-threads", "2", "-parse-as-library",
               "-module-cache-path", str(scratch / "module-cache"), "-I", str(modules), "-L", str(modules),
               "-lBrowserCore", "-I", str(baseline), *map(str, selected), str(double), "-o", str(executable)]
    with (scratch / (revision + ".build.log")).open("wb") as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    with tempfile.TemporaryDirectory(prefix="orbit-session-lock-review-") as temporary:
        root = Path(temporary).resolve() / "root"
        child = subprocess.Popen([str(executable), "--use-mock-keychain", "--orbit-data-root=" + str(root)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            stdout, stderr = child.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            child.kill(); child.communicate()
            raise AssertionError("Owned inert child exceeded deadline")
        assert child.returncode == 0 and stderr == b""
        assert stdout in [b"session-read-lock-admitted\n", b"session-read-lock-refused\n"]
        results.append({"source": revision, "childExit": child.returncode, "joined": True,
                        "persistentSessionReadLockAdmitted": stdout == b"session-read-lock-admitted\n"})
evidence = {"oldSource": old, "reviewedSource": "1216ed26c71c8a8dc136b62592197f75770fd481",
            "applicationOrCEFStarted": False, "SecItemCalls": False,
            "sourcesSHA256": {str(source.relative_to(repo)): hashlib.sha256(source.read_bytes()).hexdigest() for source in sources},
            "runtimeDoubleSHA256": hashlib.sha256(double.read_bytes()).hexdigest(), "results": results}
(scratch / "results.json").write_text(json.dumps(evidence, indent=2) + "\n")
assert results[0]["persistentSessionReadLockAdmitted"]
assert results[1]["persistentSessionReadLockAdmitted"], "R1: reviewed launcher prevents its own normal persistent-session lock"
