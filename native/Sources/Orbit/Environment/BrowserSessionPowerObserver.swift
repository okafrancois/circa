import Foundation
import IOKit
import IOKit.pwr_mgt

/// Acknowledge system sleep only after the session checkpoint has completed.
final class BrowserSessionPowerObserver: @unchecked Sendable {
    // IOMessage.h function-like macros are not imported by Swift: iokit_common_msg(message)
    // is sys_iokit (err_system(0x38)) | sub_iokit_common (0) | message.
    private static let ioKitCommon: UInt32 = 0x38 << 26
    private static let canSystemSleep: UInt32 = ioKitCommon | 0x270
    private static let systemWillSleep: UInt32 = ioKitCommon | 0x280
    private var root: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    private let flush: @MainActor @Sendable () async -> Void

    @MainActor
    init(flush: @escaping @MainActor @Sendable () async -> Void) {
        self.flush = flush
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let observer = Unmanaged<BrowserSessionPowerObserver>.fromOpaque(context).takeUnretainedValue()
            let token = Int(bitPattern: argument)
            MainActor.assumeIsolated {
                if message == BrowserSessionPowerObserver.canSystemSleep {
                    IOAllowPowerChange(observer.root, token)
                } else if message == BrowserSessionPowerObserver.systemWillSleep {
                    Task { @MainActor in
                        await observer.flush()
                        IOAllowPowerChange(observer.root, token)
                    }
                }
            }
        }, &notifier)
        if let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    deinit { stop() }

    private func stop() {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if root != 0 { IOServiceClose(root); root = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
    }
}
