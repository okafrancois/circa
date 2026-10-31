import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class FeedbackTransfer: BrowserDownloadTransfer {
    func perform(_ action: BrowserDownloadAction, completion: @escaping @MainActor (Result<Void, BrowserDownloadError>) -> Void) { completion(.success(())) }
    func invalidate() {}
}

@Suite("Sidebar download feedback", .serialized)
@MainActor
struct SidebarDownloadFeedbackTests {
    private func register(_ coordinator: BrowserDownloadCoordinator, _ profile: ProfileID) throws -> BrowserDownloadRegistration {
        try coordinator.register(owner: .init(profileID: profile), transfer: FeedbackTransfer(), suggestedFilename: "fixture.zip")
    }
    private func project(_ feedback: SidebarDownloadFeedback, _ coordinator: BrowserDownloadCoordinator, _ profile: ProfileID) {
        feedback.update(coordinator.snapshots(profileID: profile), profileID: profile)
    }

    @Test("Start and progress show the badge without opening the hover list")
    func startedAndProgress() throws {
        let coordinator = BrowserDownloadCoordinator(), profile = ProfileID(), feedback = SidebarDownloadFeedback()
        let item = try register(coordinator, profile)
        project(feedback, coordinator, profile)
        #expect(feedback.hasActiveDownloads && !feedback.isPresented)
        item.report(.init(key: item.key, sequence: 1, state: .running, receivedBytes: 40, totalBytes: 100))
        project(feedback, coordinator, profile)
        #expect(feedback.items.first?.progressFraction == 0.4)
        #expect(feedback.hasActiveDownloads && !feedback.isPresented)
    }

    @Test("Completion changes the badge once; metadata does not recreate the completion preview")
    func completion() throws {
        let coordinator = BrowserDownloadCoordinator(), profile = ProfileID(), feedback = SidebarDownloadFeedback()
        let item = try register(coordinator, profile)
        project(feedback, coordinator, profile)
        item.report(.init(key: item.key, sequence: 1, state: .complete))
        project(feedback, coordinator, profile)
        #expect(!feedback.hasActiveDownloads && feedback.completion == item.key)
        feedback.hover(true)
        project(feedback, coordinator, profile)
        #expect(feedback.isPresented && feedback.completion == nil)
        feedback.hover(false)
        project(feedback, coordinator, profile)
        #expect(!feedback.isPresented && feedback.completion == nil)
    }

    @Test("Failure and cancellation remove active status without pretending to complete", arguments: [BrowserDownloadState.failed, .cancelled])
    func unsuccessful(state: BrowserDownloadState) throws {
        let coordinator = BrowserDownloadCoordinator(), profile = ProfileID(), feedback = SidebarDownloadFeedback()
        let item = try register(coordinator, profile)
        project(feedback, coordinator, profile)
        item.report(.init(key: item.key, sequence: 1, state: state, failure: state == .failed ? .network : nil))
        project(feedback, coordinator, profile)
        #expect(!feedback.hasActiveDownloads && feedback.completion == nil)
        feedback.hover(true)
        #expect(feedback.isPresented && feedback.items.first?.state == state)
    }

    @Test("Concurrent transfers retain active status even outside the four recent rows")
    func concurrent() throws {
        let coordinator = BrowserDownloadCoordinator(), profile = ProfileID(), feedback = SidebarDownloadFeedback()
        let first = try register(coordinator, profile)
        project(feedback, coordinator, profile)
        for _ in 0..<5 {
            let item = try register(coordinator, profile)
            item.report(.init(key: item.key, sequence: 1, state: .complete))
        }
        project(feedback, coordinator, profile)
        #expect(feedback.hasActiveDownloads && feedback.recentItems.count == 4)
        first.report(.init(key: first.key, sequence: 1, state: .complete))
        project(feedback, coordinator, profile)
        #expect(!feedback.hasActiveDownloads)
    }

    @Test("Only hover opens or closes the list; elapsed time and progress do not auto-hide it")
    func hoverReopen() throws {
        let coordinator = BrowserDownloadCoordinator(), profile = ProfileID(), feedback = SidebarDownloadFeedback()
        _ = try register(coordinator, profile)
        project(feedback, coordinator, profile)
        feedback.hover(true)
        for _ in 0..<100 { project(feedback, coordinator, profile) }
        #expect(feedback.isPresented)
        feedback.hover(false); #expect(!feedback.isPresented)
        feedback.hover(true); #expect(feedback.isPresented)
    }

    @Test("Profile changes and session teardown discard transient previews; restored history never alerts")
    func sessionLifetime() throws {
        let coordinator = BrowserDownloadCoordinator(), profile = ProfileID(), other = ProfileID(), feedback = SidebarDownloadFeedback()
        let item = try register(coordinator, profile)
        item.report(.init(key: item.key, sequence: 1, state: .complete))
        project(feedback, coordinator, profile)
        #expect(feedback.completion == nil)
        feedback.hover(true); project(feedback, coordinator, other)
        #expect(feedback.items.isEmpty && !feedback.isPresented)
        project(feedback, coordinator, profile); feedback.hover(true); feedback.reset()
        #expect(feedback.items.isEmpty && feedback.completion == nil && !feedback.isPresented)
        #expect(coordinator.snapshots(profileID: profile).count == 1)
    }

    @Test("Library removal is immediately reflected and no sidebar-only history survives")
    func sourceOfTruth() throws {
        let coordinator = BrowserDownloadCoordinator(), profile = ProfileID(), feedback = SidebarDownloadFeedback()
        let item = try register(coordinator, profile)
        item.report(.init(key: item.key, sequence: 1, state: .complete))
        project(feedback, coordinator, profile); feedback.hover(true)
        try coordinator.remove(in: #require(coordinator.snapshot(for: item.key)).context)
        project(feedback, coordinator, profile)
        #expect(feedback.items.isEmpty && !feedback.isPresented)
    }

    @Test("Recent file icons fill their measured canvas instead of retaining the smaller native size")
    func iconScale() throws {
        let coordinator = BrowserDownloadCoordinator(), profile = ProfileID(), feedback = SidebarDownloadFeedback()
        _ = try register(coordinator, profile); project(feedback, coordinator, profile)
        let view = SidebarDownloadsView(frame: NSRect(x: 0, y: 0, width: 500, height: 56))
        view.render(feedback.recentItems, presented: true); view.layoutSubtreeIfNeeded()
        let row = try #require(view.subviews.first)
        let icon = try #require(row.subviews.compactMap { $0 as? NSImageView }.first)
        #expect(icon.imageScaling == .scaleProportionallyUpOrDown)
        #expect(icon.frame.size == NSSize(width: 40, height: 40))
    }

    @Test("Reduced motion retains list and badge state with no flight state to schedule")
    func reducedMotion() throws {
        let previous = OrbitMotionPreferences.overrideReducedMotion
        OrbitMotionPreferences.overrideReducedMotion = true
        defer { OrbitMotionPreferences.overrideReducedMotion = previous }
        let coordinator = BrowserDownloadCoordinator(), profile = ProfileID(), feedback = SidebarDownloadFeedback()
        _ = try register(coordinator, profile); project(feedback, coordinator, profile)
        feedback.hover(true)
        let view = SidebarDownloadsView()
        view.render(feedback.recentItems, presented: feedback.isPresented)
        #expect(!view.isHidden && feedback.hasActiveDownloads)
        #expect(view.layer?.animationKeys()?.isEmpty != false)
    }
}

@Suite("System download destination feedback", .serialized)
@MainActor
struct DownloadSystemFeedbackTests {
    @Test("File progress names the final destination and completion notifies once")
    func destinationProgress() throws {
        let previous = OrbitMotionPreferences.overrideReducedMotion
        OrbitMotionPreferences.overrideReducedMotion = false
        defer { OrbitMotionPreferences.overrideReducedMotion = previous }
        let coordinator = BrowserDownloadCoordinator(), profile = ProfileID(), feedback = BrowserDownloadSystemFeedback()
        let registration = try coordinator.register(owner: .init(profileID: profile), transfer: FeedbackTransfer())
        let destination = URL(fileURLWithPath: "/tmp/system-download-fixture.zip")
        var published: [Progress] = [], retired: [Progress] = [], finished: [URL] = []
        feedback.publish = { published.append($0) }; feedback.unpublish = { retired.append($0) }; feedback.finished = { finished.append($0) }
        feedback.image = { _ in NSImage(size: NSSize(width: 32, height: 32)) }
        let origin = NSRect(x: 20, y: 30, width: 200, height: 100)
        feedback.track(registration.key, origin: origin)
        registration.report(.init(key: registration.key, sequence: 1, state: .running, receivedBytes: 5, destinationURL: destination))
        feedback.update(try #require(coordinator.snapshot(for: registration.key)))
        let progress = try #require(published.first)
        #expect(progress.kind == .file && progress.fileOperationKind == .downloading)
        #expect(progress.fileURL == destination && progress.totalUnitCount == -1 && progress.completedUnitCount == 5)
        #expect(progress.userInfo[.fileAnimationImageKey] is NSImage)
        #expect((progress.userInfo[.fileAnimationImageOriginalRectKey] as? NSValue)?.rectValue == origin)
        registration.report(.init(key: registration.key, sequence: 2, state: .running, receivedBytes: 10, totalBytes: 20, destinationURL: destination))
        feedback.update(try #require(coordinator.snapshot(for: registration.key)))
        #expect(published.count == 1 && progress.fractionCompleted == 0.5)
        registration.report(.init(key: registration.key, sequence: 3, state: .complete, receivedBytes: 20, totalBytes: 20, destinationURL: destination))
        let complete = try #require(coordinator.snapshot(for: registration.key))
        feedback.update(complete); feedback.update(complete)
        #expect(retired.count == 1 && retired.first === progress && finished == [destination])
        #expect(progress.cancellationHandler == nil)
    }

    @Test("Failed and cancelled transfers unpublish without a completion bounce", arguments: [BrowserDownloadState.failed, .cancelled])
    func terminalWithoutCompletion(_ state: BrowserDownloadState) throws {
        let coordinator = BrowserDownloadCoordinator(), feedback = BrowserDownloadSystemFeedback()
        let item = try coordinator.register(owner: .init(profileID: ProfileID()), transfer: FeedbackTransfer())
        var publications = 0, retirements = 0, completions = 0
        feedback.publish = { _ in publications += 1 }; feedback.unpublish = { _ in retirements += 1 }; feedback.finished = { _ in completions += 1 }
        feedback.track(item.key, origin: .zero)
        item.report(.init(key: item.key, sequence: 1, state: .running, destinationURL: URL(fileURLWithPath: "/tmp/system-fixture.zip")))
        feedback.update(try #require(coordinator.snapshot(for: item.key)))
        item.report(.init(key: item.key, sequence: 2, state: state, failure: state == .failed ? .network : nil))
        feedback.update(try #require(coordinator.snapshot(for: item.key)))
        feedback.shutdown()
        #expect(publications == 1 && retirements == 1 && completions == 0)
    }

    @Test("A retained system cancellation handler cannot act after retirement")
    func retiredCancellation() async throws {
        let coordinator = BrowserDownloadCoordinator(), feedback = BrowserDownloadSystemFeedback()
        let item = try coordinator.register(owner: .init(profileID: ProfileID()), transfer: FeedbackTransfer())
        var progress: Progress?, cancellations = 0
        feedback.publish = { progress = $0 }; feedback.unpublish = { _ in }; feedback.cancel = { _ in cancellations += 1 }
        feedback.track(item.key, origin: .zero)
        item.report(.init(key: item.key, sequence: 1, state: .running, destinationURL: URL(fileURLWithPath: "/tmp/system-fixture.zip")))
        feedback.update(try #require(coordinator.snapshot(for: item.key)))
        let handler = try #require(progress?.cancellationHandler)
        handler()
        for _ in 0..<10 { await Task.yield() }
        #expect(cancellations == 1)
        feedback.retire(item.key); handler()
        for _ in 0..<10 { await Task.yield() }
        #expect(cancellations == 1)
    }

    @Test("Shutdown retires all published transfers and reduced motion omits an animated origin")
    func shutdownAndReducedMotion() throws {
        let previous = OrbitMotionPreferences.overrideReducedMotion
        OrbitMotionPreferences.overrideReducedMotion = true
        defer { OrbitMotionPreferences.overrideReducedMotion = previous }
        let coordinator = BrowserDownloadCoordinator(), feedback = BrowserDownloadSystemFeedback()
        var published: [Progress] = [], retired = 0
        feedback.publish = { published.append($0) }; feedback.unpublish = { _ in retired += 1 }
        for _ in 0..<2 {
            let item = try coordinator.register(owner: .init(profileID: ProfileID()), transfer: FeedbackTransfer())
            feedback.track(item.key, origin: NSRect(x: 1, y: 2, width: 3, height: 4))
            item.report(.init(key: item.key, sequence: 1, state: .running, destinationURL: URL(fileURLWithPath: "/tmp/system-fixture.zip")))
            feedback.update(try #require(coordinator.snapshot(for: item.key)))
        }
        #expect(published.count == 2 && published.allSatisfy { $0.userInfo[.fileAnimationImageOriginalRectKey] == nil })
        feedback.shutdown(); feedback.shutdown()
        #expect(retired == 2 && published.allSatisfy { $0.cancellationHandler == nil })
    }
}
