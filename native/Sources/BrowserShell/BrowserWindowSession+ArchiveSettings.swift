import BrowserCore

public extension BrowserWindowSession {
    /// Media collection joins this window's command queue; no detached UI task can reorder Clear.
    func clearTodayPreservingVisibleTabs(protection: @escaping @MainActor () async -> Set<TabID>) {
        enqueueOrganization { session, context in
            session.activeCommandDiagnostic?.step = "archive-media-protection"
            let protected = await protection()
            return try await session.store.clearTodayPreservingVisibleTabs(protecting: protected, from: context)
        }
    }

    /// The captured profile prevents a delayed settings or confirmation action affecting a new profile.
    func setAutoArchiveThreshold(_ threshold: BrowserAutoArchiveThreshold?, inProfile profile: ProfileID) {
        enqueueOrganization { session, context in
            if context.profileID == profile {
                try await session.store.setAutoArchiveThreshold(threshold, forProfile: profile)
            }
            return try await session.store.captureWindowState(from: context)
        }
    }

    func clearArchive(inProfile profile: ProfileID) {
        enqueueOrganization { session, context in
            guard context.profileID == profile else { return try await session.store.captureWindowState(from: context) }
            return try await session.store.clearArchive(from: context)
        }
    }
}
