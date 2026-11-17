import BrowserCore
import Testing
@testable import Orbit

struct BrowserLaunchNewTabTests {
    @Test func waitsForRestoreAndSkipsRestoredSelection() {
        let space = SpaceID()
        var launch = BrowserLaunchNewTab()
        let beforeRestore = launch.shouldPresent(isKeyWindow: true, isApplicationActive: true)
        #expect(!beforeRestore)
        launch.restore(spaceID: space, hasSelectedTab: true)
        let afterRestore = launch.shouldPresent(isKeyWindow: true, isApplicationActive: true)
        #expect(!afterRestore)
        launch.reconcile(spaceID: space, hasSelectedTab: false)
        let afterClose = launch.shouldPresent(isKeyWindow: true, isApplicationActive: true)
        #expect(!afterClose)
    }

    @Test func emptyRestorePresentsOnlyOnceWhenKeyAndActive() {
        var launch = BrowserLaunchNewTab()
        launch.restore(spaceID: SpaceID(), hasSelectedTab: false)
        let withoutKeyWindow = launch.shouldPresent(isKeyWindow: false, isApplicationActive: true)
        let whileInactive = launch.shouldPresent(isKeyWindow: true, isApplicationActive: false)
        let uponActivation = launch.shouldPresent(isKeyWindow: true, isApplicationActive: true)
        let afterPresentation = launch.shouldPresent(isKeyWindow: true, isApplicationActive: true)
        #expect(!withoutKeyWindow)
        #expect(!whileInactive)
        #expect(uponActivation)
        #expect(!afterPresentation)
    }

    @Test func aNewSelectionOrSpaceChangeCancelsDeferredPresentation() {
        let space = SpaceID()
        var launch = BrowserLaunchNewTab()
        launch.restore(spaceID: space, hasSelectedTab: false)
        launch.reconcile(spaceID: space, hasSelectedTab: true)
        launch.reconcile(spaceID: space, hasSelectedTab: false)
        let afterSelection = launch.shouldPresent(isKeyWindow: true, isApplicationActive: true)
        #expect(!afterSelection)
        launch.restore(spaceID: space, hasSelectedTab: false)
        launch.reconcile(spaceID: SpaceID(), hasSelectedTab: false)
        let afterSpaceChange = launch.shouldPresent(isKeyWindow: true, isApplicationActive: true)
        #expect(!afterSpaceChange)
    }
}
