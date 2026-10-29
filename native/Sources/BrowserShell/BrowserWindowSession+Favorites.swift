import BrowserCore

public extension BrowserWindowSession {
    /// Resolves the ordinal in command order. Reading it in `performWindowAction` and then
    /// enqueuing `selectTab` would append behind later inputs. The callback runs only after a
    /// successful selection and lets the shell focus the selected document without activating UI.
    func selectFavorite(at index: Int, onSelect: @escaping @MainActor (Surface) -> Void = { _ in }) {
        enqueue { session in
            guard let context = try await session.organizationContext(), let organization = session.organization else { return }
            let ids = organization.favorites.compactMap { $0.node.tabID }
            guard ids.indices.contains(index) else { return }
            let state = try await session.selectTabState(ids[index], from: context)
            guard !session.isClosed else { return }
            session.install(state)
            if let surface = session.selectedSurface { onSelect(surface) }
        }
    }

    /// A rename sheet may outlive page title/loading updates. Match stable identity and favorite
    /// membership at execution, rather than discarding input whenever metadata or the queue changes.
    func renameFavorite(_ id: TabID, to title: String?, inProfile profileID: ProfileID, fromSpace spaceID: SpaceID) {
        enqueue { session in
            guard let context = try await session.organizationContext(), context.profileID == profileID,
                  context.spaceID == spaceID,
                  session.organization?.favorites.contains(where: { $0.node == .tab(id) }) == true else { return }
            let state = try await session.store.renameTab(id, to: title, from: context)
            guard !session.isClosed else { return }
            session.install(state)
        }
    }
}
