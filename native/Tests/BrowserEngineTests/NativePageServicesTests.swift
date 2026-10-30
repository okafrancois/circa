import BrowserEngine
import Foundation
import Testing

@Suite("Native page service values")
struct NativePageServicesTests {
    @Test("An HTTPS error page retains its certificate and interstitial warnings")
    func security() throws {
        let data = Data(#"{"level":5,"certificateStatus":4,"certificateError":true,"displayedMixedContent":false,"ranMixedContent":true,"displayedCertificateErrorContent":false,"ranCertificateErrorContent":true,"interstitial":true}"#.utf8)
        let value = try JSONDecoder().decode(BrowserPageSecurityState.self, from: data)
        #expect(value.level == 5)
        #expect(value.certificateStatus == 4 && value.certificateError && value.interstitial)
        #expect(!value.displayedMixedContent && value.ranMixedContent)
        #expect(value.ranCertificateErrorContent)
    }
    @Test("History retains duplicate URLs as distinct indexed entries with titles")
    func history() throws {
        let data = Data(#"{"currentIndex":1,"entries":[{"index":0,"url":"https://example.invalid/","title":"First"},{"index":1,"url":"https://example.invalid/","title":"Second"}]}"#.utf8)
        let value = try JSONDecoder().decode(BrowserNavigationHistory.self, from: data)
        #expect(value.currentIndex == 1)
        #expect(value.entries.map(\.index) == [0, 1])
        #expect(value.entries.map(\.title) == ["First", "Second"])
        #expect(value.entries[0].url == value.entries[1].url)
    }
    @Test("Unknown media values survive and absent position is not measured zero")
    func media() throws {
        let data = Data(#"{"title":"Fixture","artist":"Synthetic","album":"","playbackState":7,"sessionState":9,"artwork":["https://example.invalid/art.png"],"actions":[0,1,999]}"#.utf8)
        let value = try JSONDecoder().decode(BrowserMediaSessionState.self, from: data)
        #expect(value.playbackState == 7 && value.sessionState == 9)
        #expect(value.position == nil && value.duration == nil && value.playbackRate == nil)
        #expect(value.actions == [0, 1, 999])
        #expect(value.artwork.first?.lastPathComponent == "art.png")
    }
    @Test("Opaque fullscreen origins remain explicit and permission grant scopes differ")
    func originAndGrant() {
        let change = BrowserPageFullscreenChange(entered: true, origin: "null")
        #expect(change.origin == "null" && change.entered)
        #expect(BrowserPermissionDecision.grantOnce != .grant)
    }
}
