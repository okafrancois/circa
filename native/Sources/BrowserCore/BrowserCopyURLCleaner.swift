import Foundation

/// Offline, conservative copy-time rules. Navigation and stored destinations are untouched.
public enum BrowserCopyURLCleaner {
    private struct Rules {
        let names: Set<String>
        let prefixes: [String]
        func removes(_ name: String) -> Bool {
            names.contains(name) || prefixes.contains(where: name.hasPrefix)
        }
    }
    private static let common = Rules(names: ["fbclid", "gclid"], prefixes: ["utm_"])
    private static let instagram = Rules(names: ["igsh", "igshid"], prefixes: [])
    private static let amazon = Rules(
        names: ["ref", "ref_", "tag", "linkcode", "linkid", "ascsubtag", "camp", "creative", "creativeasin", "qid", "sr", "sprefix", "crid", "dib", "dib_tag", "refrid"],
        prefixes: ["pf_rd_", "pd_rd_"])
    private static let amazonDomains: Set<String> = [
        "amazon.com", "amazon.ca", "amazon.com.mx", "amazon.com.br", "amazon.co.uk", "amazon.de",
        "amazon.fr", "amazon.it", "amazon.es", "amazon.nl", "amazon.pl", "amazon.se", "amazon.com.be",
        "amazon.ie", "amazon.co.jp", "amazon.in", "amazon.com.au", "amazon.sg", "amazon.ae",
        "amazon.sa", "amazon.com.tr", "amazon.eg", "amazon.co.za"]

    public static func clean(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host?.lowercased() else { return url }
        func belongs(to domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        let isAmazon = amazonDomains.contains(where: belongs)
        let isInstagram = belongs(to: "instagram.com")
        if let query = parts.percentEncodedQuery {
            let fields = query.components(separatedBy: "&")
            let kept = fields.filter { field in
                let name = String(field.prefix(while: { $0 != "=" })).removingPercentEncoding?.lowercased() ?? ""
                return !common.removes(name) && !(isAmazon && amazon.removes(name)) && !(isInstagram && instagram.removes(name))
            }
            if kept != fields { parts.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&") }
        }
        if isAmazon {
            parts.percentEncodedPath = parts.percentEncodedPath.components(separatedBy: "/").filter {
                let segment = $0.removingPercentEncoding?.lowercased() ?? ""
                return !segment.hasPrefix("ref=") && !segment.hasPrefix("ref_=")
            }.joined(separator: "/")
        }
        return parts.url ?? url
    }
}
