import BrowserEngine
import Foundation
import Testing

@Suite("Extension action state")
struct BrowserExtensionActionStateTests {
    @Test("Effective tab values preserve empty overrides and separate default values")
    func tabAndDefaultValues() throws {
        let json = #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Fixture","version":"1","isEnabled":true,"hasAction":true,"defaultActionState":{"title":"Default","badgeText":"9","badgeBackgroundColor":4294901760,"isEnabled":true},"actionState":{"title":"Tab","badgeText":"","badgeBackgroundColor":0,"isEnabled":false}}"#
        let summary = try JSONDecoder().decode(BrowserExtensionSummary.self, from: Data(json.utf8))
        #expect(summary.defaultActionState?.badgeText == "9")
        #expect(summary.defaultActionState?.badgeBackgroundColor == 0xffff0000)
        #expect(summary.actionState?.badgeText == "")
        #expect(summary.actionState?.badgeBackgroundColor == 0)
        #expect(summary.actionState?.isEnabled == false)
    }

    @Test("Inventory from engines without action metadata remains unavailable")
    func olderInventory() throws {
        let json = #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Fixture","version":"1","isEnabled":true,"hasAction":true}"#
        let summary = try JSONDecoder().decode(BrowserExtensionSummary.self, from: Data(json.utf8))
        #expect(summary.actionState == nil)
        #expect(summary.defaultActionState == nil)
        #expect(summary.hasOptionsPage == nil && summary.optionsURL == nil)
        #expect(summary.canAllowIncognito == nil && summary.isAllowedInIncognito == nil)
    }
    @Test("Options identity and persistent incognito preference are independent of actions")
    func optionsAndIncognito() throws {
        let json = #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Fixture","version":"1","isEnabled":true,"hasAction":false,"hasOptionsPage":true,"optionsURL":"chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/options.html","canAllowIncognito":true,"isAllowedInIncognito":false}"#
        let summary = try JSONDecoder().decode(BrowserExtensionSummary.self, from: Data(json.utf8))
        #expect(summary.hasOptionsPage == true && !summary.hasAction)
        #expect(summary.optionsURL?.host == summary.id)
        #expect(summary.optionsURL?.path == "/options.html")
        #expect(summary.canAllowIncognito == true && summary.isAllowedInIncognito == false)
    }

}
