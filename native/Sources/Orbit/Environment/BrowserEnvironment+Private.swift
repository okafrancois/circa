import BrowserEngine

extension BrowserEnvironment where Engine: BrowserPrivateEngine {
    /// No persistence destination, import lock/backup, disk settings, history or permissions.
    /// Admission precedes even the initial model task and never calls profile(for:) to inspect
    /// an untrusted persistent engine (that call could create its directory).
    convenience init(memoryOnlyEngine engine: Engine) throws {
        guard engine.persistence == .ephemeral else { throw BrowserPrivateDomainError.persistentEngine }
        guard engine.extensions == nil else { throw BrowserPrivateDomainError.extensionsEnabled }
        guard engine.capabilities.contains(.profileRemoval) else { throw BrowserPrivateDomainError.cleanupUnsupported }
        self.init(engine: engine)
        isPrivate = true
    }
}
