import Testing

/// AppKit tests share NSApplication, menu notifications, motion preferences and the main run loop.
/// MainActor alone permits interleaving at await: keep their suites under this serialized parent.
/// Explicit concurrent operations within a test and engine-independent model tests stay parallel.
@Suite(.serialized)
struct NativeWebKitTests {}
