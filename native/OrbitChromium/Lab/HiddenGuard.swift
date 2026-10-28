import AppKit
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

/// Hidden-mode enforcement for the laboratory bundle only (never linked into Orbit).
/// 1. Guard: every public AppKit path that orders a window on screen, makes it key/main or
///    activates the application is replaced in this process, so no window of the lab (or of
///    Chromium inside it) can appear. A blocked attempt is itself a violation.
/// 2. Monitor: a 100 ms timer plus window/application notifications check `NSApp.windows`,
///    activation, key/main windows and the activation policy, and CGWindowList (on-screen
///    windows owned by this process or any helper it spawned).
/// Any violation is recorded with its call site and reported once to `onViolation`, which
/// stops the run with a controlled shutdown.
@MainActor
final class HiddenGuard {
    static let shared = HiddenGuard()

    var onViolation: ((String, [String: String]) -> Void)?
    var onEvent: ((String, [String: String]) -> Void)?
    private(set) var violations: [[String: String]] = []
    private(set) var blockedAttempts: [[String: String]] = []
    private(set) var foreignWindows: [[String: String]] = []
    private(set) var policyDrifts: [[String: String]] = []
    private(set) var ticks = 0
    private(set) var cgSamples = 0
    private(set) var maxProcessTree = 0
    private(set) var maxTreeWindows = 0
    private var labWindows = Set<ObjectIdentifier>()
    private var knownWindows = Set<ObjectIdentifier>()
    private var processTree: Set<pid_t> = [getpid()]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var reported = false
    private var installed = false

    func registerLabWindow(_ window: NSWindow) { labWindows.insert(ObjectIdentifier(window)) }

    var summary: [String: Any] {
        ["ticks": ticks, "intervalMs": 100, "cgSamples": cgSamples, "violations": violations,
         "blockedAttempts": blockedAttempts, "foreignWindowsCreated": foreignWindows,
         "activationPolicyDriftsToAgent": policyDrifts,
         "maxProcessTree": maxProcessTree, "maxTreeWindowsAnyState": maxTreeWindows,
         "guardedSelectors": Self.windowSelectors + Self.applicationSelectors]
    }

    // MARK: Guard

    static let windowSelectors = ["orderWindow:relativeTo:", "orderFront:", "orderFrontRegardless", "orderBack:",
                                  "makeKeyAndOrderFront:", "makeKeyWindow", "makeMainWindow", "setIsVisible:",
                                  "deminiaturize:"]
    static let applicationSelectors = ["activateIgnoringOtherApps:", "activate", "unhide:", "unhideWithoutActivation",
                                       "arrangeInFront:", "runModalForWindow:", "setActivationPolicy:"]

    /// Installs the method replacements. Call once, before CEF creates anything.
    func install() {
        guard !installed else { return }
        installed = true
        typealias OrderIMP = @convention(c) (AnyObject, Selector, Int, Int) -> Void
        replace(NSWindow.self, "orderWindow:relativeTo:") { original, selector in
            let call = unsafeBitCast(original, to: OrderIMP.self)
            let block: @convention(block) (AnyObject, Int, Int) -> Void = { window, mode, other in
                // Ordering out stays allowed (close, hide).
                if mode == NSWindow.OrderingMode.out.rawValue { call(window, selector, mode, other); return }
                HiddenGuard.blocked("orderWindow:relativeTo:", window)
            }
            return block
        }
        for name in ["orderFront:", "orderBack:", "makeKeyAndOrderFront:", "deminiaturize:"] {
            replace(NSWindow.self, name) { _, _ in
                let block: @convention(block) (AnyObject, AnyObject?) -> Void = { window, _ in HiddenGuard.blocked(name, window) }
                return block
            }
        }
        for name in ["orderFrontRegardless", "makeKeyWindow", "makeMainWindow"] {
            replace(NSWindow.self, name) { _, _ in
                let block: @convention(block) (AnyObject) -> Void = { window in HiddenGuard.blocked(name, window) }
                return block
            }
        }
        typealias VisibleIMP = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        replace(NSWindow.self, "setIsVisible:") { original, selector in
            let call = unsafeBitCast(original, to: VisibleIMP.self)
            let block: @convention(block) (AnyObject, ObjCBool) -> Void = { window, visible in
                if !visible.boolValue { call(window, selector, visible); return }
                HiddenGuard.blocked("setIsVisible:", window)
            }
            return block
        }
        replace(NSApplication.self, "activateIgnoringOtherApps:") { _, _ in
            let block: @convention(block) (AnyObject, ObjCBool) -> Void = { _, _ in HiddenGuard.blocked("activateIgnoringOtherApps:", nil) }
            return block
        }
        for name in ["activate", "unhideWithoutActivation"] {
            replace(NSApplication.self, name) { _, _ in
                let block: @convention(block) (AnyObject) -> Void = { _ in HiddenGuard.blocked(name, nil) }
                return block
            }
        }
        for name in ["unhide:", "arrangeInFront:"] {
            replace(NSApplication.self, name) { _, _ in
                let block: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in HiddenGuard.blocked(name, nil) }
                return block
            }
        }
        // The bridge sets .prohibited before this guard can observe anything; any later change
        // away from it is refused (and is a violation).
        typealias PolicyIMP = @convention(c) (AnyObject, Selector, Int) -> ObjCBool
        replace(NSApplication.self, "setActivationPolicy:") { original, selector in
            let call = unsafeBitCast(original, to: PolicyIMP.self)
            let block: @convention(block) (AnyObject, Int) -> ObjCBool = { application, policy in
                if policy == NSApplication.ActivationPolicy.prohibited.rawValue { return call(application, selector, policy) }
                HiddenGuard.blocked("setActivationPolicy:\(policy)", nil)
                return false
            }
            return block
        }
        replace(NSApplication.self, "runModalForWindow:") { _, _ in
            let block: @convention(block) (AnyObject, AnyObject?) -> Int = { _, window in
                HiddenGuard.blocked("runModalForWindow:", window)
                return NSApplication.ModalResponse.abort.rawValue
            }
            return block
        }
    }

    private func replace(_ type: AnyClass, _ name: String, _ make: (IMP, Selector) -> Any) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type, selector) else {
            onEvent?("hidden-guard-missing-selector", ["selector": name])
            return
        }
        let original = method_getImplementation(method)
        method_setImplementation(method, imp_implementationWithBlock(make(original, selector)))
    }

    nonisolated private static func blocked(_ selector: String, _ object: AnyObject?) {
        let windowClass = object.map { String(describing: type(of: $0)) } ?? "NSApplication"
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(14).map { line in
            // Keep the symbol column only (no addresses of the private copy).
            line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ")
        }
        let record = ["selector": selector, "class": windowClass, "stack": stack.joined(separator: " | ")]
        if Thread.isMainThread {
            MainActor.assumeIsolated { HiddenGuard.shared.recordBlocked(record) }
        } else {
            DispatchQueue.main.async { HiddenGuard.shared.recordBlocked(record) }
        }
    }

    private func recordBlocked(_ record: [String: String]) {
        blockedAttempts.append(record)
        violation("blocked-" + (record["selector"] ?? "?"), record)
    }

    // MARK: Monitor

    func startMonitoring() {
        guard timer == nil else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didExposeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let name = note.name.rawValue
                let windowClass = note.object.map { String(describing: type(of: $0)) } ?? "nil"
                MainActor.assumeIsolated {
                    // An occlusion change is not a violation by itself: re-check visibility now.
                    if name == NSWindow.didChangeOcclusionStateNotification.rawValue { HiddenGuard.shared.tick(); return }
                    HiddenGuard.shared.violation("notification-" + name, ["class": windowClass])
                }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let name = note.name.rawValue
                MainActor.assumeIsolated { HiddenGuard.shared.violation("notification-" + name, [:]) }
            })
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { HiddenGuard.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func tick() {
        ticks += 1
        for window in NSApp.windows {
            let id = ObjectIdentifier(window)
            if knownWindows.insert(id).inserted, !labWindows.contains(id) {
                let record = ["class": String(describing: type(of: window)), "titleLength": String(window.title.count)]
                foreignWindows.append(record)
                onEvent?("hidden-foreign-window-created", record)
            }
            if window.isVisible || window.occlusionState.contains(.visible) {
                violation("nswindow-visible", ["class": String(describing: type(of: window)),
                                               "lab": String(labWindows.contains(id))])
            }
        }
        if NSApp.isActive { violation("application-active", [:]) }
        if NSApp.keyWindow != nil { violation("key-window", [:]) }
        if NSApp.mainWindow != nil { violation("main-window", [:]) }
        let policy = NSApp.activationPolicy()
        if policy != .prohibited {
            let detail = ["policy": String(policy.rawValue),
                          "runningApplicationPolicy": String(NSRunningApplication.current.activationPolicy.rawValue),
                          "tick": String(ticks)]
            // Regular means a Dock icon and a menu bar: a violation. An agent (accessory, the
            // bundle's declared LSUIElement type) shows neither; it is recorded and restored.
            if policy == .regular { violation("activation-policy", detail) }
            else { policyDrifts.append(detail); onEvent?("hidden-activation-policy-drift", detail) }
            NSApp.setActivationPolicy(.prohibited)
        }
        if ticks % 10 == 1 { processTree = Self.processTree(of: getpid()) }
        maxProcessTree = max(maxProcessTree, processTree.count)
        sampleWindowServer()
    }

    private func sampleWindowServer() {
        cgSamples += 1
        if let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            maxTreeWindows = max(maxTreeWindows, all.filter { owner($0).map(processTree.contains) ?? false }.count)
        }
        guard let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        for info in onScreen {
            guard let pid = owner(info), processTree.contains(pid) else { continue }
            violation("cg-onscreen-window", ["pid": String(pid), "self": String(pid == getpid()),
                                             "layer": "\(info[kCGWindowLayer as String] ?? "?")",
                                             "alpha": "\(info[kCGWindowAlpha as String] ?? "?")"])
        }
    }

    private func owner(_ info: [String: Any]) -> pid_t? {
        (info[kCGWindowOwnerPID as String] as? NSNumber).map { pid_t($0.int32Value) }
    }

    /// This process and every descendant (CEF helpers), from the kernel process table.
    nonisolated static func processTree(of root: pid_t) -> Set<pid_t> {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0 else { return [root] }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, 4, &processes, &size, nil, 0) == 0 else { return [root] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var children: [pid_t: [pid_t]] = [:]
        for process in processes.prefix(count) {
            children[process.kp_eproc.e_ppid, default: []].append(process.kp_proc.p_pid)
        }
        var tree: Set<pid_t> = [root]
        var stack = [root]
        while let next = stack.popLast() {
            for child in children[next] ?? [] where tree.insert(child).inserted { stack.append(child) }
        }
        return tree
    }

    func violation(_ kind: String, _ detail: [String: String]) {
        var record = detail
        record["kind"] = kind
        record["tick"] = String(ticks)
        if violations.count < 50 { violations.append(record) }
        onEvent?("hidden-violation", record)
        guard !reported else { return }
        reported = true
        onViolation?(kind, record)
    }
}
