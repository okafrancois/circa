import AppKit
import SwiftUI
import Testing
@testable import Orbit

/// A clock the tests move by hand; every sample is taken at an exact elapsed time.
@MainActor private final class ManualClock {
    var now: CFTimeInterval = 0
    func attach(_ ticker: OrbitFrameTicker) {
        ticker.isManual = true
        ticker.clock = { [unowned self] in now }
    }
}

private let samples: [Double] = [0, 0.016, 0.05, 0.1, 0.12, 0.2, 0.24, 0.3, 0.34, 0.38, 0.5]

@MainActor @Suite("Display-paced animations")
struct OrbitFrameTickerTests {
    @Test("Frames receive the elapsed fraction and the loop ends on the frame that delivers 1")
    func fractions() {
        let clock = ManualClock()
        let ticker = OrbitFrameTicker()
        clock.attach(ticker)
        var received: [Double] = []
        ticker.run(duration: 0.38, in: NSView()) { received.append($0) }
        for time in samples {
            clock.now = time
            ticker.tick()
        }
        let expected = samples.filter { $0 <= 0.38 }.map { min(1, $0 / 0.38) }
        #expect(received.count == expected.count)
        for (value, target) in zip(received, expected) { #expect(abs(value - target) < 1e-12) }
        #expect(!ticker.isRunning)
    }

    @Test("A view outside a visible window lands on its final frame at once")
    func detachedViewFinishes() {
        let ticker = OrbitFrameTicker()
        var received: [Double] = []
        ticker.run(duration: 0.38, in: NSView()) { received.append($0) }
        #expect(received == [1])
        #expect(!ticker.isRunning)
        var time: CFTimeInterval = 0
        ticker.start(in: NSView()) { time = $0; return true }
        #expect(time == .infinity && !ticker.isRunning)
    }

    @Test("A frame may stop its loop or start the next one")
    func reentrantFrames() {
        let clock = ManualClock()
        let ticker = OrbitFrameTicker()
        clock.attach(ticker)
        var second: [Double] = []
        ticker.run(duration: 0.1, in: NSView()) { fraction in
            guard fraction >= 1 else { return }
            ticker.run(duration: 0.1, in: NSView()) { second.append($0) }
        }
        clock.now += 0.2
        ticker.tick()
        #expect(ticker.isRunning)
        clock.now += 0.05
        ticker.tick()
        #expect(second.count == 1 && abs((second.first ?? 0) - 0.5) < 1e-9)
        var frames = 0
        ticker.start(in: NSView()) { _ in frames += 1; ticker.stop(); return true }
        ticker.tick(); ticker.tick()
        #expect(frames == 1 && !ticker.isRunning)
    }

    @Test("The assistant dock keeps its width curve: 0.38 s opening, 0.24 s closing")
    func dockCurve() {
        let clock = ManualClock()
        let card = BrowserContentCardView()
        card.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        card.present(NSView())
        clock.attach(card.assistantTicker)
        let reduced = OrbitMotionPreferences.prefersReducedMotion
        card.setAssistant(NSView(), width: 372)
        let start = clock.now
        for time in samples where time <= 0.38 {
            clock.now = start + time
            card.assistantTicker.tick()
            let expected = reduced ? 372 : 372 * BrowserAssistantMotion.progress(min(1, time / 0.38), opening: true)
            #expect(abs(card.assistantWidth - expected) < 1e-9)
        }
        #expect(!card.assistantTicker.isRunning)
        clock.now = 0
        card.setAssistant(nil, width: 0)
        let close = clock.now
        for time in samples where time <= 0.24 {
            clock.now = close + time
            card.assistantTicker.tick()
            let expected = reduced ? 372 : 372 + (0 - 372) * BrowserAssistantMotion.progress(min(1, time / 0.24), opening: false)
            #expect(abs(card.assistantWidth - (time >= 0.24 ? 0 : expected)) < 1e-9)
        }
        #expect(!card.assistantTicker.isRunning)
    }

    @Test("The palette answer keeps its height curve over 0.34 s")
    func paletteAnswerCurve() {
        let clock = ManualClock()
        let view = BrowserPaletteView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
        view.panel.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        clock.attach(view.answerTicker)
        let reduced = OrbitMotionPreferences.prefersReducedMotion
        view.updateAnswerHeight(text: "Short")
        let target = min(min(520, view.bounds.height - 100), max(230, ceil(("Short" as NSString).boundingRect(
            with: NSSize(width: max(100, view.panel.bounds.width - 86), height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)]).height) + 170))
        let initial: CGFloat = 300
        let start = clock.now
        for time in samples where time <= 0.34 {
            clock.now = start + time
            view.answerTicker.tick()
            let expected = reduced ? target : initial + (target - initial) * BrowserAssistantMotion.progress(min(1, time / 0.34), opening: true)
            #expect(abs((view.answerHeight ?? -1) - expected) < 1e-9)
        }
        #expect(!view.answerTicker.isRunning)
    }

    @Test("The Today accessory keeps its height curve over 0.34 s")
    func todayAccessoryCurve() {
        let clock = ManualClock()
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 228, height: 640))
        clock.attach(list.todayAccessoryTicker)
        list.showTodayAccessory(AnyView(Color.clear), height: 120)
        let start = clock.now
        let reduced = OrbitMotionPreferences.prefersReducedMotion
        for time in samples where time <= 0.34 {
            clock.now = start + time
            list.todayAccessoryTicker.tick()
            let expected = reduced ? 120 : 120 * BrowserAssistantMotion.progress(min(1, time / 0.34), opening: true)
            #expect(abs(list.todayAccessoryHeight - expected) < 1e-9)
            if reduced { break }
        }
        #expect(!list.todayAccessoryTicker.isRunning)
    }
}

/// Frame timing of the assistant dock reveal in a real window, sampled on every display refresh.
/// Holds the GUI slot: run only with ORBIT_PACING_GUI_BENCH set.
@MainActor @Suite("Display-paced animations on screen")
struct OrbitFrameTickerScreenTests {
    @MainActor private final class Sampler: NSObject {
        var samples: [(time: CFTimeInterval, width: CGFloat)] = []
        var period: CFTimeInterval = 0
        let read: () -> CGFloat
        init(read: @escaping () -> CGFloat) { self.read = read }
        @objc func step(_ link: CADisplayLink) {
            period = link.targetTimestamp - link.timestamp
            samples.append((CACurrentMediaTime(), read()))
        }
    }

    @Test("Dock reveal frame timing", .enabled(if: ProcessInfo.processInfo.environment["ORBIT_PACING_GUI_BENCH"] != nil))
    func dockFrameTiming() async throws {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Orbit pacing bench"
        window.isReleasedWhenClosed = false
        let card = BrowserContentCardView()
        card.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window.contentView = card
        card.present(NSView())
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(300))
        var results: [String] = []
        for _ in 0..<5 {
            let sampler = Sampler { card.assistantWidth }
            let link = card.displayLink(target: sampler, selector: #selector(Sampler.step(_:)))
            link.add(to: .main, forMode: .common)
            try await Task.sleep(for: .milliseconds(100))
            let start = CACurrentMediaTime()
            card.setAssistant(NSView(), width: 372)
            try await Task.sleep(for: .milliseconds(600))
            link.invalidate()
            let during = sampler.samples.filter { $0.time >= start && $0.time <= start + 0.42 }
            var changes: [CFTimeInterval] = []
            var stale = 0
            var last: CGFloat = -1
            for sample in during {
                if sample.width != last { changes.append(sample.time); last = sample.width }
                else if sample.width > 0 && sample.width < 372 { stale += 1 }
            }
            let intervals = zip(changes.dropFirst(), changes).map { ($0 - $1) * 1000 }
            let mean = intervals.reduce(0, +) / Double(max(1, intervals.count))
            let spread = sqrt(intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(1, intervals.count)))
            results.append(String(format: "refresh=%.2f ms vsyncs=%d updates=%d repeated-frames=%d interval mean=%.2f ms sd=%.2f ms max=%.2f ms",
                                  sampler.period * 1000, during.count, changes.count, stale, mean, spread, intervals.max() ?? 0))
            card.setAssistant(nil, width: 0)
            try await Task.sleep(for: .milliseconds(400))
        }
        // The first reveal also loads AppKit and display resources; it is a warm-up.
        for line in results.dropFirst() { print("PACING-BENCH " + line) }
    }
}
