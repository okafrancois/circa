import AppKit
import BrowserCore
import UniformTypeIdentifiers

struct BrowserImportChoice: Sendable {
    let descriptor: BrowserImportDescriptor
    let root: URL
    let profile: BrowserImportSourceProfile?
    var isSafari: Bool { descriptor.id == "safari" }
    var isFirefox: Bool { FirefoxImportRegistry.descriptors.contains(descriptor) }
    var title: String {
        if isSafari && profile == nil { return uiFormat("%@ — Export ZIP", descriptor.name) }
        return uiFormat("%@ — %@", descriptor.name, profile?.name ?? uiText("Profile unavailable"))
    }
}

enum BrowserImportInventory {
    static func choices(descriptors: [BrowserImportDescriptor], support: URL) -> [BrowserImportChoice] {
        descriptors.flatMap { descriptor -> [BrowserImportChoice] in
            let root = support.appendingPathComponent(descriptor.supportPath)
            if descriptor.id == "safari" { return [.init(descriptor: descriptor, root: root, profile: nil)] }
            let placeholder = BrowserImportSourceProfile(directory: "Default", name: "")
            let placement = ChromiumImportPlacement(importedSpace: "", bookmarkFolder: "", windowName: "")
            let profiles: [BrowserImportSourceProfile]
            do {
                if FirefoxImportRegistry.descriptors.contains(descriptor) {
                    let adapter = FirefoxBrowserImportAdapter(descriptor: descriptor, installationID: UUID(), profile: placeholder, placement: placement)
                    profiles = try adapter.discoverProfiles(metadata: BrowserImportMetadata.read(root: root, name: "profiles.ini"),
                        installs: try? BrowserImportMetadata.read(root: root, name: "installs.ini"))
                } else {
                    profiles = try ChromiumBrowserImportAdapter(descriptor: descriptor, installationID: UUID(), profile: placeholder, placement: placement)
                        .discoverProfiles(metadata: BrowserImportMetadata.read(root: root, name: "Local State", limit: 16 * 1024 * 1024))
                }
            } catch { return [.init(descriptor: descriptor, root: root, profile: nil)] }
            return profiles.isEmpty ? [.init(descriptor: descriptor, root: root, profile: nil)] : profiles.map {
                .init(descriptor: descriptor, root: root, profile: $0)
            }
        }
    }
}

@MainActor
private final class BrowserImportSourcePopup: NSPopUpButton, NSMenuDelegate {
    private(set) var isMenuOpen = false
    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, NSApp.modalWindow === window else { return }
            window.makeKey()
            _ = window.makeFirstResponder(self)
        }
    }
}

@MainActor
final class BrowserImportPicker {
    func choose(_ choices: [BrowserImportChoice], exportProfile: Bool = false, localFilesHint: String? = nil) -> BrowserImportChoice? {
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = uiText("Import from Another Browser")

        if choices.isEmpty {
            alert.informativeText = uiText("No supported browsers were detected. Install a supported browser, then try again.")
            if let localFilesHint { alert.informativeText += "\n\n" + localFilesHint }
            alert.addButton(withTitle: uiText("OK"))
            alert.runModal()
            return nil
        }
        alert.informativeText = exportProfile
            ? uiText("Choose a profile from the selected export. Any shared bookmarks and passwords will be added to its new Circa profile.")
            : uiText("Choose a browser and profile. Circa reads profile names here; no passwords or browsing data are read until you continue.")
        if let localFilesHint { alert.informativeText += "\n\n" + localFilesHint }
        let popup = BrowserImportSourcePopup(frame: NSRect(x: 0, y: 0, width: 360, height: 28), pullsDown: false)
        let menu = NSMenu()
        for choice in choices { menu.addItem(withTitle: choice.title, action: nil, keyEquivalent: "") }
        popup.menu = menu
        menu.delegate = popup
        popup.selectItem(at: 0)
        popup.refusesFirstResponder = false
        popup.setAccessibilityLabel(uiText("Browser and profile"))
        popup.setAccessibilityHelp(uiText("Choose the source profile to import into a new Circa profile."))
        alert.accessoryView = popup
        alert.addButton(withTitle: uiText("Continue"))
        alert.addButton(withTitle: uiText("Cancel"))
        alert.layout()
        let window = alert.window
        window.initialFirstResponder = popup
        // A popup consumes Return even when its menu is closed. Keep confirmation and
        // cancellation available while leaving the open menu's native navigation intact.
        let keyboard = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated {
                guard NSApp.modalWindow === window, !popup.isMenuOpen,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
                switch event.charactersIgnoringModifiers {
                case "\r": alert.buttons[0].performClick(nil); return true
                case "\u{1b}": alert.buttons[1].performClick(nil); return true
                default: return false
                }
            }
            return consumed ? nil : event
        }
        defer { if let keyboard { NSEvent.removeMonitor(keyboard) } }
        // Entering the alert's modal loop can replace its initial responder. Keep the native
        // source control keyboard-focused when the alert becomes key.
        let focus = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = window.makeFirstResponder(popup) }
        }
        defer { NotificationCenter.default.removeObserver(focus) }
        _ = window.makeFirstResponder(popup)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return choices[popup.indexOfSelectedItem]
    }

    func explain(_ choice: BrowserImportChoice) -> Bool {
        let message: String
        if choice.isSafari {
            message = uiText("In Safari, choose File > Export Browsing Data and export a ZIP. Circa can import bookmarks, the latest history visit for each URL, and passwords into one new profile. Cookies, open tabs, payment cards, extensions, settings, passkeys, password notes and verification codes are not transferred. The ZIP contains unencrypted passwords; keep it safe.")
        } else if choice.isFirefox {
            message = uiText("Quit the source browser before continuing. Circa imports available bookmarks, history, open tabs and supported cookies into a new profile. To include passwords, export logins as a CSV in the source browser and select it in the next step, or continue without passwords. Containers, partitioned cookies, site storage, extensions, form history, autofill, payment cards, permissions and search settings are not transferred.")
        } else {
            message = uiText("Quit the source browser before continuing. Circa imports available bookmarks, history, open tabs, passwords, cookies and compatible site storage into a new profile. After you choose Import, macOS may ask for access to the source browser’s Safe Storage. Encrypted bookmarks or tabs require an export and are not decoded here. Autofill, payment cards, browser account sign-in, extensions, settings, passkeys, password notes and verification codes are not transferred. Some websites may require you to sign in again.")
        }
        return confirm(title: uiFormat("Import from %@", choice.descriptor.name), message: message,
                       button: choice.isSafari ? uiText("Choose Export ZIP…") : uiText("Read Selected Data"))
    }

    func chooseFile(zip: Bool) -> URL? {
        let panel = NSOpenPanel()
        if let configuration = activeSiteSessionConfiguration(), configuration.usesMockKeychain {
            panel.directoryURL = BrowserImportUISynthetic.sourceRoot(configuration)
        }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [zip ? .zip : .commaSeparatedText]
        panel.message = zip ? uiText("Choose the ZIP exported by Safari.") : uiText("Choose the password CSV exported by your browser. The CSV contains unencrypted passwords; keep it safe.")
        panel.prompt = uiText("Choose")
        guard panel.runModal() == .OK, let file = panel.url else { return nil }
        return Self.physicalURL(file)
    }

    func chooseExternalProfile(_ profile: BrowserImportSourceProfile) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: profile.directory, isDirectory: true)
        panel.message = uiFormat("Choose the folder for %@. This profile is stored outside the browser’s standard profile folder.", profile.name)
        panel.prompt = uiText("Choose")
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        return Self.physicalURL(folder)
    }

    private static func physicalURL(_ file: URL) -> URL {
        // Expand only macOS's two standard aliases. Arbitrary user links remain refused.
        for alias in ["tmp", "var"] where file.path.hasPrefix("/" + alias + "/") {
            if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/" + alias),
               ["private/" + alias, "/private/" + alias].contains(link) {
                return URL(fileURLWithPath: "/private" + file.path)
            }
        }
        return file
    }

    func passwordCSVChoice() -> Int {
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = uiText("Include Exported Passwords?")
        alert.informativeText = uiText("Circa cannot read Firefox or Zen passwords directly. Select an exported logins CSV, or continue with the other available data.")
        alert.addButton(withTitle: uiText("Choose Password CSV…"))
        alert.addButton(withTitle: uiText("Continue Without Passwords"))
        alert.addButton(withTitle: uiText("Cancel"))
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    func confirm(title: String, message: String, button: String) -> Bool {
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: button); alert.addButton(withTitle: uiText("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func failure(_ error: any Error) {
        let alert = OrbitFloatingMaterial.alert()
        alert.alertStyle = .warning
        alert.messageText = uiText("Browser Import Could Not Be Completed")
        alert.informativeText = BrowserImportText.failure(error)
        alert.addButton(withTitle: uiText("OK")); alert.runModal()
    }
}
