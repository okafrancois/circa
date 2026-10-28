import AppKit
import OrbitChromiumBridge
import BrowserCore
import BrowserEngine
import ChromiumLifecycleStub
import Foundation

@MainActor
private final class FaviconReplayDelegate: BrowserEngineSurfaceDelegate {
    var failedNavigations = 0
    func surfaceDidStartNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFinishNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFailNavigation(_ surface: ChromiumSurface) { failedNavigations += 1 }
    func surfaceDidRequestClose(_ surface: ChromiumSurface) {}
    func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
    func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> ChromiumSurface) -> ChromiumSurface? { nil }
    func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
}

@main
@MainActor
struct FaviconReplayTests {
    static func main() async throws {
        var engine: ChromiumBrowserEngine?
        let result = ChromiumRuntime.shared.run(options: .init(rootCachePath: "/private/tmp/orbit-unused-favicon-replay-stub",
            keychainServiceName: "unused-stub", keychainAccountName: "unused-stub", hiddenApplication: true)) {
            engine = ChromiumBrowserEngine(persistence: .ephemeral)
        }
        precondition(result == 0 && engine != nil)
        let delegate = FaviconReplayDelegate()
        for name in ["fallback", "exhausted"] {
            let surface = engine!.makeSurface(profileID: ProfileID(), delegate: delegate)
            ACRStubEmit(Int32(bitPattern: ACR_EVENT_CREATED.rawValue), surface.token, 0, 2, 0, nil, nil, nil, nil)
            let file = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".receipts")
            let text = try String(contentsOf: file, encoding: .utf8)
            precondition(text.utf8.count < 8_192)
            let lines = text.split(separator: "\n")
            precondition(lines.count == 3)
            var finalPNG: Data?
            for (index, line) in lines.enumerated() {
                let fields = line.split(separator: " ").map(String.init)
                precondition(fields.count == 3)
                let revision = UInt64(fields[0])!
                let address: String? = fields[1] == "-" ? nil : fields[1]
                precondition(address == nil || ["https://fixture.example.test/a.png", "https://fixture.example.test/b.png"].contains(address!))
                var bytes = Data()
                if fields[2] != "-" {
                    let characters = Array(fields[2])
                    precondition(characters.count % 2 == 0)
                    for offset in stride(from: 0, to: characters.count, by: 2) {
                        bytes.append(UInt8(String(characters[offset...offset+1]), radix: 16)!)
                    }
                    finalPNG = bytes
                }
                bytes.withUnsafeBytes { raw in
                    ACRStubEmitFavicon(surface.token, surface.profileToken, surface.browserID, 0, revision,
                        address, bytes.isEmpty ? nil : raw.baseAddress, bytes.count)
                }
                precondition(surface.navigationState.faviconRevision == revision)
                precondition(surface.navigationState.faviconURL?.absoluteString == address)
                if index < 2 {
                    precondition(!surface.navigationState.faviconMetadataIsSettled && surface.navigationState.faviconImage == nil)
                }
                if index == 1 {
                    // A late payload from A may not replace B at B's revision.
                    let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
                    png.withUnsafeBytes { raw in
                        ACRStubEmitFavicon(surface.token, surface.profileToken, surface.browserID, 0, revision,
                            "https://fixture.example.test/a.png", raw.baseAddress, png.count)
                    }
                    precondition(surface.navigationState.faviconURL?.absoluteString == address)
                    precondition(surface.navigationState.faviconImage == nil)
                }
            }
            precondition(surface.navigationState.faviconMetadataIsSettled)
            if name == "fallback" {
                precondition(surface.navigationState.faviconImage?.png == finalPNG)
                let image = await surface.navigationState.faviconImage?.nativeImage()
                precondition(image?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 2)
                // Oversized binary receipts are definitive invalid images, not pending metadata.
                let oversized = Data(repeating: 0, count: BrowserFaviconImage.maximumBytes + 1)
                oversized.withUnsafeBytes { raw in
                    ACRStubEmitFavicon(surface.token, surface.profileToken, surface.browserID, 0, 2,
                        "https://fixture.example.test/b.png", raw.baseAddress, oversized.count)
                }
                precondition(surface.navigationState.faviconImage == nil && surface.navigationState.faviconMetadataIsSettled)
            } else {
                precondition(surface.navigationState.faviconImage == nil && surface.navigationState.faviconURL == nil)
            }
            ACRStubEmit(Int32(bitPattern: ACR_EVENT_DOCUMENT.rawValue), surface.token, 0, 0, 0,
                "https://fixture.example.test/next", nil, nil, nil)
            precondition(!surface.navigationState.faviconMetadataIsSettled && surface.navigationState.faviconRevision == 0)
            surface.dispose()
            ACRStubAbortCreation(surface.token)
        }
        print("PASS: exact producer fallback/exhaustion receipts replay through binary adapter and native decoder")
    }
}
