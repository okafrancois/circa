import AppKit
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeTabPaintHoldingTests {
    @Test("Live replacement keeps outgoing pixels until readiness or the bounded fallback", arguments: ["submitted", "timeout", "rejected"])
    func retirement(_ outcome: String) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let card = BrowserContentCardView()
        window.contentView = card
        var retirements: [@MainActor () -> Void] = []
        card.schedulePaintRetirement = { retirements.append($0) }
        let a = BrowserSplitView(), b = BrowserSplitView()
        card.present(a)
        a.suspendInteraction()
        var ready: CheckedContinuation<Bool, Never>?
        let paint = Task { await withCheckedContinuation { ready = $0 } }
        card.present(b, holdingPreviousUntil: paint)
        let parent = try #require(b.superview)
        #expect(a.window === window && b.window === window)
        #expect(parent.subviews.last === a)
        #expect(a.hitTest(.zero) == nil, "the retained document must not receive input")
        while ready == nil { await Task.yield() }
        if outcome == "timeout" { retirements[0]() }
        else {
            ready?.resume(returning: outcome == "submitted"); ready = nil
            _ = await paint.value
            for _ in 0..<20 { await Task.yield() }
            if outcome == "rejected" {
                #expect(parent.subviews.last === a, "a rejected frame must wait for the fallback")
                retirements[0]()
            }
        }
        #expect(a.superview == nil)
        #expect(b.window === window && parent.subviews.last === b)
        ready?.resume(returning: true)
        _ = await paint.value
    }

    @Test("Rapid switching retains the last displayed page and stale readiness cannot retire a newer hold")
    func rapidReturn() async throws {
        let card = BrowserContentCardView()
        var retirements: [@MainActor () -> Void] = []
        card.schedulePaintRetirement = { retirements.append($0) }
        var completions: [CheckedContinuation<Bool, Never>] = []
        func barrier() -> Task<Bool, Never> {
            Task { await withCheckedContinuation { completions.append($0) } }
        }
        let a = NSView(), b = NSView(), c = NSView()
        card.present(a)
        let first = barrier()
        card.present(b, holdingPreviousUntil: first)
        let second = barrier()
        card.present(c, holdingPreviousUntil: second)
        #expect(c.superview?.subviews.last === a)
        while completions.count < 2 { await Task.yield() }
        completions[0].resume(returning: true); _ = await first.value
        for _ in 0..<20 { await Task.yield() }
        retirements[0]()
        #expect(c.superview?.subviews.last === a)
        card.prepareToReparent(a)
        card.present(a, holdingPreviousUntil: second)
        #expect(a.superview?.subviews.last === a, "returning to the displayed page must not cover it with an unready intermediate page")
        completions[1].resume(returning: true); _ = await second.value
        for _ in 0..<20 { await Task.yield() }
        retirements[1]()
        #expect(a.superview != nil && card.isPresenting(a))
        #expect(b.superview == nil && c.superview == nil)
    }

    @Test("Split transitions and an empty card keep their existing presentation path")
    func splitAndEmpty() async {
        let card = BrowserContentCardView()
        card.schedulePaintRetirement = { _ in Issue.record("Split transitions must not hold outgoing pixels") }
        let a = NSView(), split = NSView(), b = NSView()
        let paint = Task { true }
        card.present(a)
        card.present(split, isSplit: true, holdingPreviousUntil: paint)
        #expect(a.superview == nil)
        card.present(b, holdingPreviousUntil: paint)
        #expect(split.superview == nil)
        card.present(nil, holdingPreviousUntil: paint)
        #expect(b.superview == nil)
        _ = await paint.value
    }
}
}
