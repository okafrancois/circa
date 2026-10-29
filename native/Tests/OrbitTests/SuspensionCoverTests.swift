import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

@Suite("Compressed suspension snapshot budgets")
struct SuspensionCoverStoreTests {
    @Test func boundedLRU() {
        var store = BrowserSuspensionCoverStore(budget: 10, perTabLimit: 6)
        let a = TabOccurrenceID(), b = TabOccurrenceID(), c = TabOccurrenceID()
        func cover(_ count: Int) -> BrowserSuspensionCover {
            .init(jpeg: Data(repeating: 0, count: count), size: .init(width: 20, height: 10), scale: 2,
                  url: URL(string: "https://memory.test")!, generation: 1)
        }
        store.insert(cover(4), for: a); store.insert(cover(4), for: b)
        _ = store.value(for: a)
        store.insert(cover(5), for: c)
        #expect(store.value(for: b) == nil)
        #expect(store.count == 2 && store.byteCount == 9)
        store.insert(cover(7), for: b)
        #expect(store.count == 2 && store.byteCount == 9)
        store.retain([c])
        #expect(store.count == 1 && store.byteCount == 5)
        store.remove(c)
        #expect(store.byteCount == 0)
    }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SuspensionCoverTests {
    enum End: CaseIterable { case paint, selection, navigation, resize, timeout, interruptedCapture, failedCapture }

    @Test("A covered wake rejects stale paint and retires on paint or an invalidating event", arguments: End.allCases)
    func paintAndCancellation(_ end: End) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.tabSuspension.close(); owner.session.close(); owner.window?.close(); environment.autoArchive.scheduler.stop() }
        let url = URL(string: "https://memory.test/covered")!
        owner.openTab(url: url)
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface)
        let id = try #require(owner.session.occurrenceID(for: surface))
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        surface.allowsSuspension = true; surface.supportsSuspensionPaint = true
        surface.snapshotHandler = { request in
            if end == .failedCapture { throw BrowserEngineError.snapshotUnavailable }
            if end == .interruptedCapture { surface.allowsSuspension = false }
            let width = Int(request.width ?? 100)
            let height = max(1, Int(CGFloat(width) * surface.hostView.bounds.height / surface.hostView.bounds.width))
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return BrowserSurfaceSnapshot(image: try #require(context.makeImage()), documentGeneration: surface.documentGeneration)
        }
        owner.openTab(url: URL(string: "https://memory.test/other")!)
        await owner.session.waitForPendingCommands()
        owner.tabSuspension.selectionDidChange()
        let discarded = await owner.tabSuspension.sweep(now: ProcessInfo.processInfo.systemUptime + 3601)
        if end == .interruptedCapture || end == .failedCapture {
            #expect(discarded == 0 && surface.suspensionCount == 0 && owner.tabSuspension.covers.byteCount == 0)
            return
        }
        #expect(discarded == 1)
        #expect(owner.tabSuspension.covers.count == 1 && owner.tabSuspension.covers.byteCount > 0)
        owner.session.selectOccurrence(id)
        await owner.session.waitForPendingCommands()
        #expect(owner.tabSuspension.activeCoverIDs == [id])
        surface.suspensionPaintGeneration = surface.documentGeneration
        surface.onChange?()
        #expect(owner.tabSuspension.activeCoverIDs == [id])
        let nativeContent = NSView(frame: surface.hostView.bounds)
        nativeContent.wantsLayer = true
        surface.hostView.addSubview(nativeContent, positioned: .below, relativeTo: nil)
        nativeContent.layer?.add(CATransition(), forKey: kCATransition)
        switch end {
        case .paint:
            surface.navigate(to: url)
            #expect(owner.tabSuspension.activeCoverIDs == [id])
            surface.suspensionPaintGeneration = surface.documentGeneration
            surface.onChange?()
        case .selection:
            owner.openTab(url: URL(string: "https://memory.test/selected")!)
            await owner.session.waitForPendingCommands()
        case .navigation:
            surface.navigate(to: URL(string: "https://memory.test/navigated")!)
        case .resize:
            surface.hostView.setFrameSize(.init(width: surface.hostView.frame.width + 5, height: surface.hostView.frame.height))
        case .timeout:
            try await Task.sleep(for: .milliseconds(1600))
        case .interruptedCapture, .failedCapture: break
        }
        #expect(owner.tabSuspension.activeCoverIDs.isEmpty && owner.tabSuspension.covers.byteCount == 0)
        #expect(nativeContent.layer?.animation(forKey: kCATransition) == nil)
    }

    @Test func resizeInvalidatesWithoutInterceptingInput() throws {
        let context = try #require(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let view = BrowserSuspensionCoverView(image: try #require(context.makeImage()), size: .init(width: 10, height: 10), scale: 1)
        view.needsDisplay = true
        view.displayIfNeeded()
        #expect(view.layer?.contents != nil)
        var removed = false
        view.resized = { removed = true }
        #expect(view.hitTest(.init(x: 2, y: 2)) == nil)
        view.setFrameSize(.init(width: 11, height: 10))
        #expect(removed)
    }
}
}
