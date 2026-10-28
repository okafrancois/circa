// Links the unmodified product launcher and preparation sources to inert local boundaries.
// No CEF/engine library, NSApplication instance, window, network or Keychain is started.
import AppKit
import Foundation

struct BrowserEnvironment<Engine> {}
struct BrowserWindowController<Engine> {}
struct ChromiumBrowserEngine {
    enum Persistence { case persistent, ephemeral }
    init(persistence: Persistence, hostedWhenAvailable: Bool) {}
}
enum OrbitStableSigning { static let rootSHA1 = "" }
struct ReviewRuntimeOptions {}

@MainActor
func reviewTrace(_ name: String) { FileHandle.standardOutput.write(Data((name + "\n").utf8)) }

@MainActor
final class ChromiumRuntime {
    static var shared: ChromiumRuntime { reviewTrace("runtime-shared"); return ChromiumRuntime() }
    func run(options: ReviewRuntimeOptions, ready: () -> Void) -> Int32 {
        reviewTrace("runtime-run")
        // Never invoke the AppKit/application callback.
        return 0
    }
}

@MainActor
func productRuntimeOptions(_ configuration: OrbitProductConfiguration, extraSwitches: [String], hiddenApplication: Bool) -> ReviewRuntimeOptions {
    reviewTrace("runtime-options"); return ReviewRuntimeOptions()
}

@MainActor
final class ReviewLaunchHooks: OrbitLaunchHooks {
    var runtimeSwitches: [String] { reviewTrace("hook-switches"); return [] }
    var hiddenApplication: Bool { reviewTrace("hook-hidden"); return true }
    func willStartRuntime(_ configuration: OrbitProductConfiguration) { reviewTrace("hook-will-start") }
    func runtimeDidBecomeReady(_ configuration: OrbitProductConfiguration) { fatalError("The inert runtime must not become ready") }
}

@MainActor
func orbitLaunchHooks() -> (any OrbitLaunchHooks)? { reviewTrace("hook-factory"); return ReviewLaunchHooks() }

@MainActor
final class ColdLaunchOpenQueue {
    static let shared = ColdLaunchOpenQueue()
    func install() { reviewTrace("cold-launch-install") }
    func deliver(to: OrbitApplication, application: NSApplication) { fatalError("No application delivery is allowed") }
}

@MainActor
final class OrbitApplication: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { fatalError("No application is allowed") }
}

@main
struct AuthenticationLauncherIndependentReview {
    @MainActor static func main() { OrbitLauncher.run() }
}
