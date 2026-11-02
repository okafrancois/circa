import AppKit
import BrowserCore
import BrowserShell
@_spi(Testing) import ChromiumEngine
import Foundation

/// Confined opt-in diagnostic: response contents and account identity never leave memory.
@MainActor
enum OrbitGitHubCompatibilityProbe {
    static func run(_ application: OrbitApplication, root: URL, action: String) async -> [String: Any] {
        let allowedRoot = URL(fileURLWithPath: "/private/tmp/pull-requests-live-folder/restart/synthetic-data").resolvingSymlinksInPath().path
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.pr-live-folder.synthetic",
              root.resolvingSymlinksInPath().path == allowedRoot,
              CommandLine.arguments.contains("--use-mock-keychain"),
              let environment = application.environment,
              let owner = environment.liveControllers.first,
              let profileID = owner.session.activeProfileID,
              let window = owner.window, window.isVisible, NSApp.isActive,
              NSRunningApplication.current.bundleURL?.resolvingSymlinksInPath().path == Bundle.main.bundleURL.resolvingSymlinksInPath().path else {
            return ["guard": false,
                "bundle": Bundle.main.bundleIdentifier == "lab.orbit.orbit.pr-live-folder.synthetic",
                "root": root.resolvingSymlinksInPath().path == allowedRoot,
                "mock": CommandLine.arguments.contains("--use-mock-keychain"),
                "active": NSApp.isActive,
                "controller": application.environment?.liveControllers.first != nil,
                "profile": application.environment?.liveControllers.first?.session.activeProfileID != nil,
                "visible": application.environment?.liveControllers.first?.window?.isVisible == true,
                "ownBundle": NSRunningApplication.current.bundleURL?.resolvingSymlinksInPath().path == Bundle.main.bundleURL.resolvingSymlinksInPath().path]
        }
        var report: [String: Any] = ["guard": true]
        var phases: [String] = []
        ChromiumGitHubDiagnostics.phase = { phases.append($0); report["phase"] = $0; report["phases"] = phases }
        defer { ChromiumGitHubDiagnostics.phase = nil }
        do {
            let query = action == "public" ? "is:pr is:open repo:openai/codex" : "is:pr is:open author:@me"
            let response = try await owner.engine.pullRequests(profileID: profileID, query: query, page: 1)
            report["status"] = response.status
            if let document = try? XMLDocument(xmlString: response.body, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) {
                for name in ["user-login", "octolytics-actor-id", "octolytics-actor-login"] {
                    report[name] = !(try document.nodes(forXPath: "//meta[@name='\(name)']/@content")).isEmpty
                }
                let scripts = try document.nodes(forXPath: "//script[@data-target='react-app.embeddedData']")
                report["embeddedScripts"] = scripts.count
                let links = try document.nodes(forXPath: "//a/@href").compactMap { $0.stringValue }.compactMap { URL(string: $0, relativeTo: URL(string: "https://github.com")!) }
                for name in ["q", "query"] {
                    report["authoredLinkParameter_" + name] = links.filter { $0.path == "/pulls/authored" }.contains {
                        URLComponents(url: $0.absoluteURL, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == name } == true
                    }
                    report["inputName_" + name] = !(try document.nodes(forXPath: "//input[@name='\(name)']")).isEmpty
                }
                for path in ["/pulls/search", "/pulls/custom", "/pulls/inbox", "/pulls/authored", "/pulls/created"] {
                    report["link" + path.replacingOccurrences(of: "/", with: "_")] = links.contains { $0.host == "github.com" && $0.path == path }
                }
                let recognized = Set(["payload", "pullsDashboardSurfaceContentRoute", "repoPullsDashboardContentRoute", "results", "currentPage", "totalPages", "totalCount", "viewer", "user", "id", "login", "pullRequests", "data", "query", "search", "edges", "nodes", "pageInfo", "pulls", "type", "pullsDashboard", "pullRequestsDashboard", "pullsDashboardSearch", "pullsSearchResults", "pullsDashboardSearchRoute", "pullRequestsSearchRoute", "pullsDashboardContentRoute", "pullsDashboardQueryRoute", "searchResults", "pagination", "page", "pageCount", "pageSize", "page_count", "page_size", "result_count", "resultCount", "current_page", "total_pages", "total_count", "issues", "items", "issue", "pullRequest", "author", "repository", "number", "url", "globalId", "permalink", "updatedAt", "updated_at", "state", "title", "isDraft", "cursor", "hasNextPage", "count", "searchQuery", "metadata", "routes", "route", "appPayload", "initialPayload", "pull_requests", "pullRequestsSearch", "searchResultsRoute", "dataType", "searchType", "result_count", "page_count", "pageCount", "resultCount", "pageInfo", "nodes", "edges", "node", "endCursor", "hasNextPage", "sections", "groups", "view", "views", "queryString", "size", "offset", "limit", "startCursor"])
                var keys = Set<String>()
                var queryEchoed = false
                let viewerLogin = try document.nodes(forXPath: "//meta[@name='user-login']/@content").first?.stringValue ?? ""
                let expectedQueries = [query, query.replacingOccurrences(of: "@me", with: viewerLogin)].map { Set($0.split(whereSeparator: \.isWhitespace).map(String.init)) }
                func findQuery(_ value: Any) {
                    if let text = value as? String, expectedQueries.contains(Set(text.split(whereSeparator: \.isWhitespace).map(String.init))) { queryEchoed = true }
                    if let dict = value as? [String: Any] { for child in dict.values { findQuery(child) } }
                    else if let list = value as? [Any] { for child in list { findQuery(child) } }
                }
                var schema: [String: String] = [:]
                var pagination: [String: Int] = [:]
                func inspect(_ value: Any, path: String = "root") {
                    if let dict = value as? [String: Any] {
                        schema[path] = "object"
                        for (key, child) in dict {
                            let route = key.hasPrefix("pulls") && key.hasSuffix("Route") && key.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
                            if recognized.contains(key) || route { keys.insert(key); inspect(child, path: path + "." + key) }
                        }
                    } else if let list = value as? [Any] {
                        schema[path] = "array"; if let first = list.first { inspect(first, path: path + "[]") }
                    } else if value is String { schema[path] = "string" }
                    else if value is NSNull { schema[path] = "null" }
                    else if let number = value as? NSNumber {
                        schema[path] = "numberOrBool"
                        if ["currentPage", "totalPages", "totalCount"].contains(path.components(separatedBy: ".").last ?? ""), path.contains(".pageInfo.") { pagination[path] = number.intValue }
                    }
                }
                for script in scripts {
                    if let text = script.stringValue, let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) { inspect(json); findQuery(json) }
                }
                if action == "public" {
                    for script in scripts {
                        if let text = script.stringValue, let data = text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let payload = json["payload"] as? [String: Any],
                           let content = payload["pullsDashboardSurfaceContentRoute"] as? [String: Any],
                           let rows = content["results"] as? [[String: Any]] {
                            report["publicScopeMatches"] = !rows.isEmpty && rows.allSatisfy {
                                guard let raw = $0["permalink"] as? String, let url = URL(string: raw) else { return false }
                                return url.host == "github.com" && url.path.split(separator: "/").prefix(2).joined(separator: "/") == "openai/codex"
                            }
                            report["openStateCount"] = rows.filter { $0["state"] as? String == "OPEN" }.count
                            report["legacyOpenStateCount"] = rows.filter { $0["state"] as? String == "REPO_PULL_REQUEST_STATE_OPEN" }.count
                            report["validTimestampCount"] = rows.filter { ($0["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } != nil }.count
                        }
                    }
                }
                report["recognizedKeys"] = keys.sorted(); report["schema"] = schema; report["queryEchoed"] = queryEchoed; report["pagination"] = pagination
            }
            report["phase"] = "decode"
            let page = try BrowserGitHubWebPage(html: response.body)
            report["decoded"] = true; report["items"] = page.items.count
            if ["workflow", "restart"].contains(action) {
                report["workflow"] = try await workflow(application, account: page.account, restart: action == "restart")
            }
        } catch let error as BrowserGitHubProviderError {
            switch error {
            case .signedOut: report["error"] = "signedOut"
            case .singleSignOnRequired: report["error"] = "singleSignOnRequired"
            case .invalidResponse: report["error"] = "invalidResponse"
            default: report["error"] = "providerFailure"
            }
        } catch { report["error"] = "otherFailure" }
        return report
    }
    private static func workflow(_ application: OrbitApplication, account: BrowserGitHubAccount, restart: Bool) async throws -> [String: Any] {
        guard let environment = application.environment, let owner = environment.liveControllers.first,
              let context = await owner.session.captureContextInCommandOrder().value else { return ["context": false] }
        let runtime = environment.liveFolders
        var checks: [String: Any] = [:]
        func gate() -> Bool {
            guard let window = owner.window, NSApp.keyWindow === window, NSApp.isActive,
                  let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
            return rows.contains { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier }
        }
        func invoke(_ item: NSMenuItem?) -> Bool {
            guard gate(), let item, let action = item.action, let target = item.target as? NSObject else { return false }
            target.perform(action, with: item); return true
        }
        func wait(_ predicate: () async -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while ContinuousClock.now < deadline {
                if await predicate() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
        let before = await environment.store.sessionDocument()
        var folder = before.organization.folders.first { $0.liveFolder != nil }
        checks["restored"] = folder != nil
        if folder == nil, !restart {
            checks["nativeActivation"] = invoke(owner.makeLiveFoldersCreationMenu(spaceID: context.spaceID)?.submenu?.items.first)
            checks["created"] = await wait {
                let document = await environment.store.sessionDocument()
                return document.organization.folders.contains { $0.liveFolder != nil && runtime.lastFetched($0.id) != nil }
            }
            folder = await environment.store.sessionDocument().organization.folders.first { $0.liveFolder != nil }
        }
        guard let folder else { return checks }
        let connection = try await runtime.connection(context.profileID)
        checks["bindingMatches"] = connection.boundAccount?.id == account.id
        checks["folderCount"] = await environment.store.sessionDocument().organization.folders.filter { $0.liveFolder != nil }.count
        func options() async -> NSMenu? {
            owner.session.synchronizeOrganization()
            await owner.session.waitForPendingCommands()
            guard case let .folder(item)? = owner.session.organization?.item(for: .folder(folder.id)), let config = item.liveFolder else { return nil }
            return owner.makeLiveFolderContextMenu(folder: item, configuration: config)?.menu.items.first?.submenu
        }
        if !restart {
            for (index, expected) in [false, true].enumerated() {
                let menu = await options()
                let old = runtime.lastFetched(folder.id)
                checks["filterAction\(index)"] = invoke(menu?.items.first { $0.title == uiText("Review Requests") })
                checks["filterFetched\(index)"] = await wait {
                    let configuration = await runtime.configuration(folder.id)
                    return configuration?.filters.contains(.reviewRequested) == expected && runtime.lastFetched(folder.id) != old
                }
            }
        }
        let menu = await options()
        let old = runtime.lastFetched(folder.id)
        checks["refreshAction"] = invoke(menu?.items.first { $0.title == uiText("Refresh") })
        checks["refreshFetched"] = await wait { runtime.lastFetched(folder.id) != old }
        let after = await environment.store.sessionDocument()
        checks["spaceCountUnchanged"] = before.spaces.count == after.spaces.count
        let rows = after.organization.tabs.filter { $0.liveFolderChild?.folderID == folder.id }
        checks["rows"] = rows.count
        checks["rowOpening"] = "syntheticOnly"
        // Only known public project rows may be opened in the genuine-profile probe.
        let publicRepositories = Set(["openai/codex", "swiftlang/swift", "microsoft/vscode"])
        if let row = rows.first(where: { publicRepositories.contains($0.url.path.split(separator: "/").prefix(2).joined(separator: "/")) }), gate() {
            owner.session.selectTab(row.id)
            await owner.session.waitForPendingCommands()
            checks["publicRowOpened"] = await wait {
                owner.session.selectedSurface?.profileID == context.profileID && owner.session.selectedSurface?.navigationState.url == row.url
            }
            checks["rowOpening"] = "knownPublic"
        }
        try await runtime.persist(context.profileID)
        return checks
    }

}
