import BrowserCore
import BrowserEngine
import BrowserShell
import SwiftUI

@MainActor
struct BrowserAirTrafficControlView<Engine: BrowserEngine>: View {
    @ObservedObject var model: BrowserSettingsModel<Engine>
    @ObservedObject var runtime: BrowserSettingsRuntime
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor: BrowserLinkRoutingEditor<Engine>

    init(model: BrowserSettingsModel<Engine>, runtime: BrowserSettingsRuntime) {
        self.model = model
        self.runtime = runtime
        _editor = StateObject(wrappedValue: BrowserLinkRoutingEditor(model: model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(uiText("Air Traffic Control")).font(Font(BrandTextStyle.ui.font(size: 21, weight: .semibold)))
                Spacer()

            }
            Text(uiFormat("Routes let you choose where specific sites open inside %@. For example, you can route Spotify links to always open inside your Personal space.", BrowserCommandMenus<BrowserWindowController<Engine>>.applicationDisplayName))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(editor.routes) { route in
                        routeRow(route)
                    }
                    if editor.routes.isEmpty {
                        VStack(spacing: 10) {
                            OrbitIcon.view(sfName: "arrow.turn.down.right", pointSize: 28, weight: .light).font(.system(size: 28, weight: .light))
                            Text(uiText("Create a route to send links to a Space automatically."))
                        }.foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 110)
                    }
                }.padding(1)
            }.frame(minHeight: 130, maxHeight: 290)
            Divider()
            HStack {
                Button(uiText("New Route"), systemImage: "plus") {
                    editor.add()
                }.disabled(model.catalog.spaces.isEmpty || editor.routes.contains { !$0.isValid })
                    .accessibilityIdentifier("routing-new-route")
                Spacer()
                Text(uiText("Default")).fontWeight(.medium)
                Picker(uiText("Default destination"), selection: Binding(get: { runtime.document.linkRouting.defaultDestination }, set: { destination in
                    model.perform {
                        try await runtime.store.setLinkDefaultDestination(destination)
                        await runtime.refresh()
                    }
                })) {
                    Text(uiText("Little Circa")).tag(BrowserLinkDefaultDestination.quickWindow)
                    Text(uiText("Most Recent Space")).tag(BrowserLinkDefaultDestination.mostRecentSpace)
                    Divider()
                    ForEach(model.catalog.spaces, id: \.id) { space in
                        Text(spaceLabel(space)).tag(BrowserLinkDefaultDestination.space(space.id))
                    }
                }.labelsHidden().frame(width: 190).accessibilityIdentifier("routing-default")
            }
            HStack {
                Text(uiText("Routes apply to links from other apps. The first matching route wins."))
                    .font(Font(BrandFonts.ui(11))).foregroundStyle(.secondary)
                Spacer()
                Button(uiText("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(editor.routes.contains { !$0.isValid } || model.isBusy)
                    .accessibilityIdentifier("routing-done")
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(Font(BrandFonts.ui(12))) }
        }
        .padding(22).frame(width: 560)
        .font(Font(BrandFonts.ui(13))).foregroundStyle(OrbitSettingsStyle.foreground)
        .settingsFrost()
        .disabled(!model.acceptsActions || runtime.isUnavailable)
        .onAppear { editor.load() }
    }

    private func routeRow(_ route: BrowserLinkRoute) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Picker(uiText("URL match"), selection: routeBinding(route, \.match)) {
                Text(uiText("contains")).tag(BrowserLinkMatch.contains)
                Text(uiText("is equal to")).tag(BrowserLinkMatch.equals)
                Text(uiText("host is")).tag(BrowserLinkMatch.host)
            }.labelsHidden().frame(width: 100).accessibilityIdentifier("routing-match-" + route.id.uuidString)
                .help(uiText("If URL"))
            TextField(uiText("example.org"), text: routeBinding(route, \.value))
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("routing-value-" + route.id.uuidString)
            Picker(uiText("Destination Space"), selection: routeBinding(route, \.spaceID)) {
                ForEach(model.catalog.spaces, id: \.id) { space in Text(spaceLabel(space)).tag(space.id) }
            }.labelsHidden().frame(width: 140).accessibilityIdentifier("routing-space-" + route.id.uuidString)
                .help(uiText("Open in"))
            HStack(spacing: 5) {
                Button { editor.move(route.id, offset: -1) } label: { OrbitIcon.view(sfName: "chevron.up", pointSize: 13).font(.system(size: 13)) }
                    .disabled(editor.routes.contains { !$0.isValid } || editor.routes.first?.id == route.id).help(uiText("Move route up"))
                Button { editor.move(route.id, offset: 1) } label: { OrbitIcon.view(sfName: "chevron.down", pointSize: 13).font(.system(size: 13)) }
                    .disabled(editor.routes.contains { !$0.isValid } || editor.routes.last?.id == route.id).help(uiText("Move route down"))
            }.buttonStyle(.plain)
            Button {
                editor.remove(route.id)
            } label: { OrbitIcon.view(sfName: "minus.circle.fill", pointSize: 13).font(.system(size: 13)).foregroundStyle(.secondary) }
                .buttonStyle(.plain).help(uiText("Remove route"))
                .accessibilityLabel(uiText("Remove route"))
                .accessibilityIdentifier("routing-remove-" + route.id.uuidString)
        }
        .padding(10).background(OrbitSettingsStyle.panel, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(OrbitSettingsStyle.border, lineWidth: 1))
    }

    private func routeBinding<Value>(_ route: BrowserLinkRoute, _ keyPath: WritableKeyPath<BrowserLinkRoute, Value>) -> Binding<Value> {
        Binding(get: {
            (editor.routes.first { $0.id == route.id } ?? route)[keyPath: keyPath]
        }, set: { value in
            editor.update(route.id, keyPath: keyPath, value: value)
        })
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
