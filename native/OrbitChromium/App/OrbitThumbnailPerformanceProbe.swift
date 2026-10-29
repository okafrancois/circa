import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Darwin
import ImageIO
import UniformTypeIdentifiers

@MainActor enum OrbitThumbnailPerformanceProbe {
    static var tabs: [TabOccurrenceID] = []
    static func cpu() -> Double {
        var value = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1e9
    }
    static func run(_ owner: OrbitWindowController, command: [String: String], root: URL) async -> [String: Any] {
        guard let window = owner.window, window.isVisible else { return ["error": "window"] }
        let step = command["step"] ?? ""
        guard !["switches", "covers"].contains(step) || tabs.count == 3 else { return ["error": "prepare-first"] }
        var output: [String: Any] = ["occlusionBefore": window.occlusionState.contains(.visible)]
        if step == "prepare" {
            tabs = Array(owner.session.snapshot!.tabs.prefix(3).map(\.occurrenceID))
            for id in tabs {
                owner.session.selectOccurrence(id); await owner.session.waitForPendingCommands()
                if let surface = owner.session.selectedSurface {
                    let deadline = ProcessInfo.processInfo.systemUptime + 8
                    while (!surface.isReady || surface.navigationState.isLoading) && ProcessInfo.processInfo.systemUptime < deadline {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            output["prepared"] = tabs.count
        } else if step == "measure", let surface = owner.session.selectedSurface {
            for width: CGFloat in [200, surface.hostView.bounds.width * (window.backingScaleFactor)] {
                var rows: [[String: Any]] = []
                for index in 0..<5 {
                    var counts: [String: Int] = [:]
                    ChromiumSurface.snapshotProbe = { key, value in counts[key, default: 0] += key.hasSuffix("Bytes") ? value : 1 }
                    let begin = ProcessInfo.processInfo.systemUptime, c = cpu()
                    if let snapshot = try? await surface.captureSnapshot(.init(width: width)) {
                        rows.append(["wallMS": (ProcessInfo.processInfo.systemUptime-begin)*1000, "mainMS": (cpu()-c)*1000,
                                     "width": snapshot.image.width, "height": snapshot.image.height, "counts": counts])
                        if index == 0 { save(snapshot.image, root.appendingPathComponent("capture-\(Int(width)).png")) }
                    }
                    ChromiumSurface.snapshotProbe = nil
                }
                output["captures-\(Int(width))"] = rows
            }
            if let api = surface.pagePerformance {
                var rows: [[String: Any]] = []
                for _ in 0..<5 {
                    let begin = ProcessInfo.processInfo.systemUptime, c = cpu()
                    let (_, data) = await surface.devToolsCall("Page.captureScreenshot", params: #"{"format":"png","captureBeyondViewport":false}"#)
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if let encoded = object?["data"] as? String, let png = Data(base64Encoded: encoded),
                       let source = CGImageSourceCreateWithData(png as CFData,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil),
                       let tint = BrowserPageTint.sampledTopEdge(image) {
                        rows.append(["path":"png","wallMS":(ProcessInfo.processInfo.systemUptime-begin)*1000,"mainMS":(cpu()-c)*1000,"transportBytes":data.count,"decodedBytes":image.bytesPerRow*image.height,"tint":[tint.red,tint.green,tint.blue]])
                    }
                    let nativeBegin = ProcessInfo.processInfo.systemUptime, nc = cpu()
                    var request = BrowserNativeCaptureRequest(outputWidth:64,outputHeight:1)
                    request.width = Int32(surface.hostView.bounds.width); request.height = 2
                    let capture = await api.capture(request)
                    if let provider = CGDataProvider(data:capture.pixels as CFData), capture.status == .captured,
                       let image = CGImage(width:64,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:256,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent),
                       let tint = BrowserPageTint.sampledTopEdge(image) {
                        rows.append(["path":"native","wallMS":(ProcessInfo.processInfo.systemUptime-nativeBegin)*1000,"mainMS":(cpu()-nc)*1000,"transportBytes":capture.pixels.count,"decodedBytes":capture.pixels.count,"tint":[tint.red,tint.green,tint.blue]])
                    }
                }
                output["tintCaptures"] = rows
            }
        } else if step == "switches" {
            var counts: [String: Int] = [:]
            ChromiumSurface.snapshotProbe = { key, value in counts[key, default: 0] += key.hasSuffix("Bytes") ? value : 1 }
            let c = cpu(), begin = ProcessInfo.processInfo.systemUptime
            for i in 0..<50 {
                owner.session.selectOccurrence(tabs[i % tabs.count]); await owner.session.waitForQueuedCommands()
                try? await Task.sleep(for: .milliseconds(12))
            }
            try? await Task.sleep(for: .milliseconds(700))
            output["mainMS"] = (cpu()-c)*1000; output["wallMS"] = (ProcessInfo.processInfo.systemUptime-begin)*1000
            output["counts"] = counts
            ChromiumSurface.snapshotProbe = nil
            output["thumbnailCount"] = owner.session.ownedSurfaces.filter { owner.tabSwitcher.snapshots.image(for: $0) != nil }.count
        } else if step == "idle", let surface = owner.session.selectedSurface {
            var preferences = owner.siteControls.preferences.preferences(url: surface.navigationState.committedURL, profileID: surface.profileID)
            preferences.developerMode = true
            try? owner.siteControls.preferences.set(preferences, url: surface.navigationState.committedURL, profileID: surface.profileID)
            owner.renderDeveloperToolbar()
            try? await Task.sleep(for: .seconds(1))
            let c = cpu(), begin = ProcessInfo.processInfo.systemUptime
            try? await Task.sleep(for: .seconds(6))
            output["mainMS"] = (cpu()-c)*1000; output["wallMS"] = (ProcessInfo.processInfo.systemUptime-begin)*1000
            output["tint"] = surface.navigationState.pageTint.map { [Int($0.red),Int($0.green),Int($0.blue)] }
            surface.setPageTintObservationEnabled(false)
        } else if step == "covers" {
            var rows: [[String: Any]] = []
            for i in 0..<10 {
                let id = tabs[i % 2], anchor = tabs[(i+1) % 2]
                owner.session.selectOccurrence(anchor); await owner.session.waitForPendingCommands()
                try? await Task.sleep(for: .milliseconds(100))
                _ = await owner.tabSuspension.sweep(now: ProcessInfo.processInfo.systemUptime+3601)
                guard let surface = owner.session.surface(for: id) else { break }
                var store = owner.tabSuspension.covers
                guard surface.isSuspended, let cover = store.value(for: id) else { return ["error": "discard-or-cover-missing"] }
                owner.session.selectOccurrence(id); await owner.session.waitForPendingCommands()
                let mounted = owner.tabSuspension.activeCoverIDs.contains(id)
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while owner.tabSuspension.activeCoverIDs.contains(id), ProcessInfo.processInfo.systemUptime < deadline {
                    try? await Task.sleep(for: .milliseconds(2))
                }
                let (_, reply) = await surface.devToolsCall("Runtime.evaluate", params: #"{"expression":"document.wasDiscarded","returnByValue":true}"#)
                let value = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
                rows.append(["mounted": mounted, "suspendedBefore": true, "wasDiscarded": (value?["result"] as? [String: Any])?["value"] as? Bool ?? false,
                             "bytes": cover.jpeg.count,"painted": surface.suspensionPaintGeneration == surface.documentGeneration])
                try? await Task.sleep(for: .milliseconds(180))
            }
            output["wakes"] = rows
        }
        output["occlusionAfter"] = window.occlusionState.contains(.visible)
        return output
    }
    static func save(_ image: CGImage, _ url: URL) {
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
        }
    }
}
