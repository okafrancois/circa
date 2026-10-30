import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@MainActor
struct ObjectEditingUITests {
    @Test("Tab icon choices apply live, retain the picker, reset, and cancel without another write")
    func liveIconPicker() {
        let picker = SpaceIconPicker(currentChoice: .none, accent: .defaultSpace, purpose: .tab)
        picker.loadViewIfNeeded()
        var choices: [BrowserSpaceIcon] = []
        picker.onChooseIcon = { choices.append($0) }
        #expect(picker.removeButton.isHidden)
        picker.choose(.grapheme("😀"))
        #expect(choices == [.grapheme("😀")] && !picker.removeButton.isHidden)
        #expect(picker.canPresent)
        picker.removeIcon(nil)
        #expect(choices == [.grapheme("😀"), .none] && picker.removeButton.isHidden)
        picker.cancel()
        picker.choose(.grapheme("😃"))
        #expect(choices.count == 2)
    }

    @Test("URL drafts cancel without saving, save once, and validate before acceptance")
    func pinnedDraft() {
        let original = URL(string: "https://example.test/home")!
        var saved: [URL] = []
        let cancelled = PinnedURLEditor(url: original) { saved.append($0) }
        cancelled.loadViewIfNeeded()
        cancelled.field.stringValue = "https://example.test/cancelled"
        cancelled.complete(save: false)
        #expect(saved.isEmpty)
        let editor = PinnedURLEditor(url: original) { saved.append($0) }
        editor.loadViewIfNeeded()
        editor.field.stringValue = ""
        editor.refreshValidation()
        editor.complete(save: true)
        #expect(!editor.saveButton.isEnabled && saved.isEmpty)
        editor.field.stringValue = "https://example.test/replaced"
        editor.refreshValidation()
        editor.complete(save: true)
        editor.complete(save: true)
        #expect(saved == [URL(string: "https://example.test/replaced")!])
    }

    @Test("Custom icon raster is reused synchronously in rows")
    func imageReuse() {
        let first = SpaceIconImages.tabImage(.grapheme("😀"))
        #expect(first != nil && first === SpaceIconImages.tabImage(.grapheme("😀")))
        #expect(SpaceIconImages.tabImage(nil) == nil)
    }
}
}

extension NativeWebKitTests.ObjectEditingUITests {
    @Test("Detached Space previews retain custom tab icons before a live surface exists")
    func previewIcon() {
        let profile = ProfileID(), space = SpaceID(), id = TabID(), date = Date()
        let tab = BrowserOrganizedTab(id: id, url: URL(string: "https://example.test")!, createdAt: date,
                                      lastActiveAt: date, customIcon: .grapheme("😀"))
        let document = BrowserSessionDocument(profiles: [.init(id: profile, name: "Synthetic")],
            spaces: [.init(id: space, profileID: profile, name: "Space")], windows: [], tabs: [],
            organization: .init(tabs: [tab], folders: [], favorites: [],
                spaces: [.init(spaceID: space, pinned: [], today: [.tab(id)])], archive: [], archivePolicy: .init()))
        let preview = SpaceSwipePreview.content(document: document, spaceID: space)
        #expect(preview.tabs.first?.customIcon == .grapheme("😀"))
    }
}
