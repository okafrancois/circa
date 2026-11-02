import Foundation

/// Fail-closed decoder for the structured pull dashboard. Unknown documents never mean empty.
/// Only the small title/URL/revision projection leaves this decoder; HTML is not persisted.
public struct BrowserGitHubWebPage: Sendable {
    public let account: BrowserGitHubAccount
    public let items: [BrowserLiveFolderFetchedItem]
    public let currentPage: Int
    public let totalPages: Int
    public let totalCount: Int

    public init(html: String) throws {
        guard html.utf8.count <= 8 * 1_024 * 1_024,
              let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) else {
            throw BrowserGitHubProviderError.invalidResponse
        }
        func meta(_ name: String) throws -> String? {
            try document.nodes(forXPath: "//meta[@name='\(name)']/@content").first?.stringValue
        }
        guard let login = try meta("user-login"), !login.isEmpty else { throw BrowserGitHubProviderError.signedOut }
        guard BrowserGitHubPullRequestsProvider.validLogin(login),
              let rawID = try meta("octolytics-actor-id"), let id = Int64(rawID), id > 0 else {
            throw BrowserGitHubProviderError.invalidResponse
        }
        account = .init(id: id, login: login)
        if !(try document.nodes(forXPath: "//a[contains(@href, '/orgs/') and contains(@href, '/sso')]")).isEmpty {
            throw BrowserGitHubProviderError.singleSignOnRequired
        }
        let scripts = try document.nodes(forXPath: "//script[@data-target='react-app.embeddedData']")
        var content: Content?
        for script in scripts {
            guard let text = script.stringValue, let data = text.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["payload"] as? [String: Any] else { continue }
            // Require a known route, never recursively accept unrelated embedded search results.
            for key in ["pullsDashboardSurfaceContentRoute", "repoPullsDashboardContentRoute"] {
                if let value = payload[key] {
                    guard content == nil, JSONSerialization.isValidJSONObject(value) else {
                        throw BrowserGitHubProviderError.invalidResponse
                    }
                    content = try JSONDecoder().decode(Content.self, from: JSONSerialization.data(withJSONObject: value))
                }
            }
        }
        guard let content, content.currentPage >= 1, content.totalPages >= 0, content.totalCount >= 0,
              content.currentPage <= max(1, content.totalPages), content.results.count <= 100,
              content.totalCount >= content.results.count,
              content.totalCount == 0 || content.totalPages > 0,
              content.totalCount != 0 || content.results.isEmpty,
              !content.results.isEmpty || content.totalCount == 0 else { throw BrowserGitHubProviderError.invalidResponse }
        currentPage = content.currentPage; totalPages = content.totalPages; totalCount = content.totalCount
        items = try content.results.map { row in
            guard !row.globalId.isEmpty, let url = URL(string: row.permalink), url.scheme == "https",
                  url.host == "github.com", url.port == nil, url.user == nil, url.password == nil,
                  url.fragment == nil, url.query == nil, BrowserGitHubPullRequestsProvider.validPullURL(url),
                  ISO8601DateFormatter().date(from: row.updatedAt) != nil,
                  ["REPO_PULL_REQUEST_STATE_OPEN", "OPEN"].contains(row.state) else { throw BrowserGitHubProviderError.invalidResponse }
            return .init(identity: .init(itemID: "github.com:\(id):\(row.globalId)"), url: url,
                         title: row.title, fingerprint: row.updatedAt + ":" + row.title)
        }
    }
    private struct Content: Decodable {
        let results: [Row]
        let currentPage: Int
        let totalPages: Int
        let totalCount: Int

        private enum CodingKeys: String, CodingKey { case results, currentPage, totalPages, totalCount, pageInfo }
        private struct PageInfo: Decodable { let currentPage: Int; let totalPages: Int; let totalCount: Int }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            results = try values.decode([Row].self, forKey: .results)
            if values.contains(.pageInfo) {
                guard !values.contains(.currentPage), !values.contains(.totalPages), !values.contains(.totalCount) else {
                    throw BrowserGitHubProviderError.invalidResponse
                }
                let page = try values.decode(PageInfo.self, forKey: .pageInfo)
                currentPage = page.currentPage; totalPages = page.totalPages; totalCount = page.totalCount
            } else {
                currentPage = try values.decode(Int.self, forKey: .currentPage)
                totalPages = try values.decode(Int.self, forKey: .totalPages)
                totalCount = try values.decode(Int.self, forKey: .totalCount)
            }
        }
    }
    private struct Row: Decodable {
        let globalId: String
        let permalink: String
        let updatedAt: String
        let state: String
        let title: String
        private enum CodingKeys: String, CodingKey { case globalId, id, permalink, updatedAt, state, title }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.id) != values.contains(.globalId) else { throw BrowserGitHubProviderError.invalidResponse }
            globalId = try values.decode(String.self, forKey: values.contains(.id) ? .id : .globalId)
            permalink = try values.decode(String.self, forKey: .permalink)
            updatedAt = try values.decode(String.self, forKey: .updatedAt)
            state = try values.decode(String.self, forKey: .state)
            title = try values.decode(String.self, forKey: .title)
        }
    }
}
