import Foundation

/// Shared by the page and object menus. Titles cannot break the link label or its destination.
enum BrowserMarkdownLink {
    static func format(title: String?, url: URL) -> String {
        let label = (title?.isEmpty == false ? title! : url.absoluteString)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let destination = url.absoluteString.replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        return "[\(label)](\(destination))"
    }
}
