import Darwin
import Foundation
import WebKit

/// Whether the networking process serving `dataStore` is clamped to the kernel's darwinbg band
/// (MAXPRI_THROTTLE). Nil when WebKit has no networking process or the probe is unavailable.
@MainActor
func nativeWebKitNetworkingIsBackground(_ dataStore: WKWebsiteDataStore) -> Bool? {
    guard let pid = nativeWebKitNetworkingProcess(dataStore) else { return nil }
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
    return info.pti_priority <= 4
}

@MainActor
func nativeWebKitNetworkingState(_ dataStore: WKWebsiteDataStore) -> String {
    guard let pid = nativeWebKitNetworkingProcess(dataStore) else { return "no networking process" }
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return "networking pid=\(pid), no task info" }
    return "networking pid=\(pid), base priority=\(info.pti_priority)"
}

@MainActor
private func nativeWebKitNetworkingProcess(_ dataStore: WKWebsiteDataStore) -> pid_t? {
    let selector = NSSelectorFromString("_networkProcessIdentifier")
    guard dataStore.responds(to: selector) else { return nil }
    typealias ProcessIdentifier = @convention(c) (AnyObject, Selector) -> pid_t
    let pid = unsafeBitCast(dataStore.method(for: selector), to: ProcessIdentifier.self)(dataStore, selector)
    return pid > 0 ? pid : nil
}
