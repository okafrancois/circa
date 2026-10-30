import BrowserCore
import BrowserEngine
import BrowserShell
import SwiftUI

@MainActor
struct BrowserAirTrafficControlView<Engine: BrowserEngine>: View {
    @ObservedObject var model: BrowserSettingsModel<Engine>
    @ObservedObject var runtime: BrowserSettingsRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [BrowserLinkRoute] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(uiText("Air Traffic Control")).font(.system(size: 21, weight: .semibold))
                Spacer()
                Button(uiText("New Route"), systemImage: "plus") {
                    if let space = model.catalog.spaces.first {
                        drafts.append(.init(value: "", spaceID: space.id))
                    }
                }.disabled(model.catalog.spaces.isEmpty || drafts.contains { !$0.isValid })
                    .accessibilityIdentifier("routing-new-route")
            }
            Text(uiFormat("Routes let you choose where specific sites open inside %@. For example, you can route Spotify links to always open inside your Personal space.", BrowserCommandMenus<BrowserWindowController<Engine>>.applicationDisplayName))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($drafts) { $route in
                        routeRow($route)
                    }
                    if drafts.isEmpty {
                        VStack(spacing: 10) {
                            OrbitIcon.view(sfName: "arrow.turn.down.right", pointSize: 28).font(.system(size: 28, weight: .light))
                            Text(uiText("Create a route to send links to a Space automatically."))
                        }.foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 110)
                    }
                }.padding(1)
            }.frame(minHeight: 130, maxHeight: 290)
            Divider()
            HStack {
                Text(uiText("Default")).fontWeight(.medium)
                Spacer()
                Picker(uiText("Default destination"), selection: Binding(get: { runtime.document.linkRouting.defaultDestination }, set: { destination in
                    model.perform {
                        try await runtime.store.setLinkDefaultDestination(destination)
                        await runtime.refresh()
                    }
                })) {
                    Text(uiText("Little Orbit")).tag(BrowserLinkDefaultDestination.quickWindow)
                    Text(uiText("Most Recent Space")).tag(BrowserLinkDefaultDestination.mostRecentSpace)
                    Divider()
                    ForEach(model.catalog.spaces, id: \.id) { space in
                        Text(spaceLabel(space)).tag(BrowserLinkDefaultDestination.space(space.id))
                    }
                }.labelsHidden().frame(width: 250).accessibilityIdentifier("routing-default")
            }
            HStack {
                Text(uiText("Routes apply to links from other apps. The first matching route wins."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(uiText("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(drafts.contains { !$0.isValid } || model.isBusy)
                    .accessibilityIdentifier("routing-done")
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
        }
        .padding(24).frame(width: 650)
        .font(.system(size: 13)).foregroundStyle(OrbitSettingsStyle.foreground)
        .background(OrbitSettingsStyle.background)
        .disabled(!model.acceptsActions || runtime.isUnavailable)
        .onAppear { drafts = runtime.document.linkRouting.rules.filter { route in model.catalog.spaces.contains { $0.id == route.spaceID } } }
    }

    private func routeRow(_ binding: Binding<BrowserLinkRoute>) -> some View {
        let route = binding.wrappedValue
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(uiText("If URL"))
                    Picker(uiText("URL match"), selection: binding.match) {
                        Text(uiText("contains")).tag(BrowserLinkMatch.contains)
                        Text(uiText("is equal to")).tag(BrowserLinkMatch.equals)
                        Text(uiText("host is")).tag(BrowserLinkMatch.host)
                    }.labelsHidden().frame(width: 120).accessibilityIdentifier("routing-match-" + route.id.uuidString)
                    TextField(uiText("example.org"), text: binding.value)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("routing-value-" + route.id.uuidString)
                }
                HStack {
                    OrbitIcon.view(sfName: "arrow.turn.down.right", pointSize: 13).foregroundStyle(.secondary)
                    Text(uiText("Open in"))
                    Picker(uiText("Destination Space"), selection: binding.spaceID) {
                        ForEach(model.catalog.spaces, id: \.id) { space in Text(spaceLabel(space)).tag(space.id) }
                    }.labelsHidden().accessibilityIdentifier("routing-space-" + route.id.uuidString)
                    Spacer()
                }
            }
            VStack(spacing: 5) {
                Button { move(route.id, offset: -1) } label: { OrbitIcon.view(sfName: "chevron.up", pointSize: 13) }
                    .disabled(drafts.contains { !$0.isValid } || drafts.first?.id == route.id).help(uiText("Move route up"))
                Button { move(route.id, offset: 1) } label: { OrbitIcon.view(sfName: "chevron.down", pointSize: 13) }
                    .disabled(drafts.contains { !$0.isValid } || drafts.last?.id == route.id).help(uiText("Move route down"))
            }.buttonStyle(.plain)
            Button {
                drafts.removeAll { $0.id == route.id }
                model.perform { try await runtime.store.removeLinkRoute(route.id); await runtime.refresh() }
            } label: { OrbitIcon.view(sfName: "minus.circle.fill", pointSize: 13).foregroundStyle(.secondary) }
                .buttonStyle(.plain).help(uiText("Remove route"))
                .accessibilityLabel(uiText("Remove route"))
        }
        .padding(12).background(OrbitSettingsStyle.panel, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(OrbitSettingsStyle.border, lineWidth: 1))
        .onChange(of: route) { _, changed in
            guard changed.isValid else { return }
            model.perform { try await model.saveLinkRoute(changed) }
        }
    }

    private func move(_ id: UUID, offset: Int) {
        guard let index = drafts.firstIndex(where: { $0.id == id }), drafts.indices.contains(index + offset) else { return }
        drafts.swapAt(index, index + offset)
        model.perform { try await runtime.store.moveLinkRoute(id, offset: offset); await runtime.refresh() }
    }

    private func spaceLabel(_ space: BrowserSpace) -> String {
        guard model.catalog.profiles.count > 1,
              let profile = model.catalog.profiles.first(where: { $0.id == space.profileID }) else { return space.name }
        return space.name + " · " + profile.name
    }
}

extension BrowserSettingsModel {
    func saveLinkRoute(_ route: BrowserLinkRoute) async throws {
        guard await environment.store.catalogSnapshot().spaces.contains(where: { $0.id == route.spaceID }) else {
            throw BrowserStoreError.spaceMissing
        }
        try await runtime.store.saveLinkRoute(route)
        await runtime.refresh()
    }
}
