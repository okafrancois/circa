import Foundation

public enum BrowserGitHubProviderError: Error, Equatable, Sendable {
    case signedOut, accountChanged, singleSignOnRequired, accessDenied, invalidResponse, invalidConfiguration
    case rateLimited(until: Date)
    case server(status: Int)
}

public struct BrowserGitHubAccount: Codable, Equatable, Sendable {
    public let id: Int64
    public let login: String
    public init(id: Int64, login: String) { self.id = id; self.login = login }
}

/// Query contract shared by the profile web provider and synthetic fixtures. This does not
/// authorize requests: all GitHub requests must stay inside the owning browser profile.
public enum BrowserGitHubPullRequestsProvider {
    /// Relationship filters are a union. Drafts modify each relationship query. Unsupported
    /// stored filters are rejected rather than silently changing the user's requested scope.
    public static func queries(_ configuration: BrowserLiveFolderConfiguration, login: String) throws -> [String] {
        guard validLogin(login), configuration.filters.isSubset(of: [.authored, .reviewRequested, .drafts]),
              configuration.excludedRepositories.allSatisfy(validRepository) else {
            throw BrowserGitHubProviderError.invalidConfiguration
        }
        var predicates: [String] = []
        if configuration.filters.contains(.authored) { predicates.append("author:\(login)") }
        // GitHub's review-requested qualifier includes requests addressed to the user's teams.
        if configuration.filters.contains(.reviewRequested) { predicates.append("review-requested:\(login)") }
        let exclusions = configuration.excludedRepositories.sorted().map { "-repo:\($0)" }
        return try predicates.map { predicate in
            let words = ["is:pr", "is:open", predicate]
                + (configuration.filters.contains(.drafts) ? [] : ["draft:false"]) + exclusions
            let query = words.joined(separator: " ")
            guard query.utf8.count <= 2_000 else { throw BrowserGitHubProviderError.invalidConfiguration }
            return query
        }
    }

    static func validLogin(_ login: String) -> Bool {
        !login.isEmpty && login.utf8.count <= 39 && login.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }
    static func validRepository(_ repository: String) -> Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && validLogin(String(parts[0])) && !parts[1].isEmpty
            && parts[1] != "." && parts[1] != ".." && parts[1].utf8.count <= 100
            && parts[1].utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }
    }
    static func validPullURL(_ url: URL) -> Bool {
        let parts = url.path.split(separator: "/")
        return parts.count == 4 && validRepository(parts.prefix(2).joined(separator: "/"))
            && parts[2] == "pull" && parts[3].allSatisfy(\.isNumber)
    }

}
