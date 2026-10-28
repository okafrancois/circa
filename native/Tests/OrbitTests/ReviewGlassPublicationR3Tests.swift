import BrowserCore
import BrowserEngineConformance
import Combine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Independent glass publication R3", .serialized)
@MainActor
struct ReviewGlassPublicationR3Tests {
    @Test("First fresh Settings catalog publishes while same-scope admission remains reserved")
    func catalogPublicationPrecedesAdmission() async throws {
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, profile) = try await environment.initialContext.value
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        let applied = BrowserThemeSurface(material: .liquidGlass, transparency: 0.88)
        var sawFreshCatalog = false
        // @Published delivers synchronously. Observe the first publication rather than waiting
        // for isBusy to clear, which would hide a lease released before the outer reload.
        let observation = model.$catalog.sink { catalog in
            MainActor.assumeIsolated {
                guard !sawFreshCatalog,
                      catalog.spaces.first(where: { $0.id == space })?.theme?.surface == applied else { return }
                sawFreshCatalog = true
                #expect(!environment.themeEditors.canBeginEditing(spaceID: space, profileID: profile))
            }
        }
        defer { observation.cancel() }
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile,
                                         material: .liquidGlass, transparency: 0.88)
        try await model.suspendForTermination(timeout: .seconds(20))
        #expect(sawFreshCatalog)
        #expect(!model.isBusy && model.errorMessage == nil)
        #expect(model.catalog.spaces.first(where: { $0.id == space })?.theme?.surface == applied)
        #expect(try await environment.store.spaceTheme(space)?.surface == applied)
        #expect(environment.themeEditors.canBeginEditing(spaceID: space, profileID: profile))
        model.resumeAfterCancelledTermination()
    }
}
}
