import AppKit
import BrowserCore
import QuartzCore

extension OrbitSmokeDriver {
    /// Grain themes and fixed-progress Space swipe frames, captured from the real window without
    /// sending input, plus the paper grain repaint count and paint time over a 120-frame swipe.
    func uiPerfGuardsScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        func check(_ name: String, _ passed: Bool, _ evidence: [String: Any] = [:]) {
            self.check("ui-perf-guards." + name, passed, evidence)
        }
        guard let window = owner.window, let screen = NSScreen.main?.visibleFrame else { check("window", false); return }
        func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        let light = OrbitTokens.SpaceTheme(stops: [color(0.93, 0.86, 0.78), color(0.80, 0.87, 0.95)],
                                           mode: .light, texture: .grain, textureIntensity: 0.3)
        let lightStrong = OrbitTokens.SpaceTheme(stops: [color(0.86, 0.93, 0.84), color(0.95, 0.90, 0.80)],
                                                 mode: .light, texture: .grain, textureIntensity: 0.8)
        let dark = OrbitTokens.SpaceTheme(stops: [color(0.10, 0.12, 0.20), color(0.22, 0.10, 0.18)],
                                          mode: .dark, texture: .grain, textureIntensity: 0.6)
        let shell = owner.windowShell
        window.setFrame(NSRect(x: screen.minX + 40, y: screen.maxY - 860, width: 1280, height: 820), display: true)
        window.orderFrontRegardless()
        func owns() -> Bool {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
            return window.isVisible && rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        _ = await until(3) { owns() }
        guard owns() else { check("capture-owner", false); return }
        func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
        func capture(_ name: String) async {
            await settle()
            guard owns() else { check("capture-owner", false); return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), runRoot.appendingPathComponent(name + ".png").path]
            try? process.run()
            process.waitUntilExit()
            check("capture." + name, process.terminationStatus == 0)
        }
        func show(_ theme: OrbitTokens.SpaceTheme) {
            OrbitSpaceThemes.resolver = { _, _ in theme }
            shell.applySpaceSwipeBlend(nil)
            shell.apply(theme: theme, animated: false)
        }
        show(light)
        await capture("light")
        show(dark)
        await capture("dark")
        show(light)
        await settle()
        for (name, destination) in [("dark", dark), ("light-strong", lightStrong)] {
            for progress: CGFloat in [0.25, 0.5, 0.75] {
                shell.applySpaceSwipeBlend(SpaceSwipeThemeBlend(source: light, destination: destination, progress: progress))
                await capture("swipe-\(name)-\(Int(progress * 100))")
            }
            shell.applySpaceSwipeBlend(nil)
        }

        // One swipe, painted synchronously frame by frame as the display link would.
        let grains = [shell.themeFill.paperGrain, shell.floatingBackdrop.fill.paperGrain]
        var report: [String: Any] = [:]
        for (name, destination) in [("dark", dark), ("light-strong", lightStrong)] {
            show(light)
            await settle()
            window.displayIfNeeded()
            CATransaction.flush()
            var repaints = 0
            let start = CACurrentMediaTime()
            for frame in 0..<120 {
                let progress = CGFloat(frame) / 119
                shell.applySpaceSwipeBlend(SpaceSwipeThemeBlend(source: light, destination: destination, progress: progress))
                repaints += grains.filter { $0.layer?.needsDisplay() == true }.count
                window.displayIfNeeded()
                CATransaction.flush()
            }
            let elapsed = (CACurrentMediaTime() - start) * 1000
            shell.applySpaceSwipeBlend(nil)
            report[name] = ["frames": 120, "grainRepaints": repaints, "totalMilliseconds": elapsed,
                            "millisecondsPerFrame": elapsed / 120]
        }
        report["backingScale"] = window.backingScaleFactor
        report["contentSize"] = [window.contentLayoutRect.width, window.contentLayoutRect.height]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: runRoot.appendingPathComponent("swipe-paint.json"))
        }
        check("swipe-paint", !report.isEmpty, report)
        show(light)
    }
}
