import Foundation

/// Orbit's own onboarding copy; every string is localizable.
@MainActor
enum OrbitOnboardingText {
    static var windowTitle: String { uiText("Welcome to Circa") }
    static var welcomeHeadline: String { uiText("Welcome home.") }
    static var getStarted: String { uiText("Open Circa") }
    static var start: String { uiText("Start") }
    static var bringOver: String { uiText("Bring it over") }
    static var welcomeBody: String { uiText("Let’s set up your browser. A few short steps, about a minute, and nothing leaves your Mac.") }
    static var welcomeSticker: String { uiText("Your Spaces come too →") }
    static var favouritesTitle: String { uiText("Pin your favourites.") }
    static var favouritesBody: String { uiText("Pick a few sites to keep at the top of the sidebar, in every Space. You can change them any time.") }
    static var favouritesImportedBody: String { uiText("These are the sites you visited most. Pick the ones you want at the top of the sidebar, in every Space.") }
    static func favouriteHint(_ count: Int) -> String { uiFormat("%d selected · add more from the sidebar menu", count) }
    static func counter(_ step: Int) -> String { uiFormat("STEP %d OF 7", step) }
    static func sticker(duration: Double?, sync: Bool) -> String {
        let privacy = sync ? uiText("synced to your iCloud") : uiText("nothing uploaded")
        // A sub-second import still reads as one second, never "0 s".
        return duration.map { uiFormat("%d s · %@", max(1, Int($0.rounded())), privacy) } ?? privacy
    }
    static var next: String { uiText("Next") }
    static var back: String { uiText("Back") }
    static var skip: String { uiText("Skip for now") }

    static var importTitle: String { uiText("Bring your browser over.") }
    static var importBody: String { uiText("Tabs, Spaces, bookmarks, history and passwords move into Circa. Nothing is uploaded, and the other browser stays exactly as it is.") }
    static var importNote: String { uiText("macOS may ask to unlock the other browser’s passwords when the import starts.") }
    static var importNone: String { uiText("No thanks, I’ll start fresh.") }
    static var importNoneEmpty: String { uiText("No other browser was found. Start fresh.") }
    static var importListLabel: String { uiText("Browsers to import from") }
    static var profileListLabel: String { uiText("Profile to import") }

    static var syncTitle: String { uiText("Take your Spaces everywhere.") }
    static var syncBody: String { uiText("Circa can keep your Spaces, tabs and settings in sync through your private iCloud account. No Circa account needed.") }
    static var syncUnavailable: String { uiText("iCloud sync isn’t available in this copy of Circa. You can keep everything on this Mac.") }
    static var syncSignedOut: String { uiText("Sign in to iCloud in System Settings to sync. You can turn sync on later in Circa Settings.") }
    static var syncYesStrong: String { uiText("YES,") }
    static var syncYes: String { uiText("sync with iCloud.") }
    static var syncNoStrong: String { uiText("NO,") }
    static var syncNo: String { uiText("keep it on this Mac.") }

    static var themeTitle: String { uiText("Make it feel like yours.") }
    static var themeBody: String { uiText("Pick a colour for your first Space, or drag the two dots to mix your own. You can change it any time from the sidebar.") }

    static var defaultTitle: String { uiText("Open your links in Circa?") }
    static var defaultBody: String { uiText("Make Circa your default browser so links from other apps open here. You can change it anytime in System Settings.") }
    static var defaultYesStrong: String { uiText("YES,") }
    static var defaultYes: String { uiText("open my links in Circa.") }
    static var defaultNoStrong: String { uiText("NO,") }
    static var defaultNo: String { uiText("not right now.") }

    static var finishTitle: String { uiText("Your Spaces are waiting.") }
    static var finishBody: String { uiText("Your first Space is ready. Circa is yours to explore.") }
    static var finishImportBody: String { uiText("Everything is right where you left it.") }
}
