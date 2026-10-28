import Foundation

public extension BrowserOrganizationTabItem {
    /// Read-only, non-live representation. It grants no occurrence or profile-selection authority.
    static func favoritePreview(_ tab: BrowserOrganizedTab, profileID: ProfileID, selected: Bool) -> Self {
        Self(id: tab.id, section: .favorites(profileID), url: tab.url, pinnedURL: tab.pinnedURL,
             pageTitle: tab.pageTitle, customTitle: tab.customTitle, occurrenceID: nil,
             isLoadedInThisWindow: false, isSelected: selected, isOpenInAnotherWindow: false)
    }
}
