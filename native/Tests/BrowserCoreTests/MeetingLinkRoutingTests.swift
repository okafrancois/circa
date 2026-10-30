import Foundation
import Testing
@testable import BrowserCore

struct MeetingLinkRoutingTests {
    static let meetings = ["https://meet.google.com/abc-defg-hij", "https://us02web.zoom.us/j/123",
                           "https://zoom.us/my/room", "https://teams.microsoft.com/l/meetup-join/synthetic",
                           "https://teams.live.com/meet/123", "https://around.co/r/synthetic",
                           "https://app.around.co/rooms/synthetic"]

    @Test("Meeting links override defaults, while the first available explicit route still wins", arguments: meetings)
    func precedence(address: String) throws {
        let url = try #require(URL(string: address))
        let a = SpaceID(), b = SpaceID()
        for destination: BrowserLinkDefaultDestination in [.quickWindow, .mostRecentSpace, .space(a)] {
            var routing = BrowserLinkRouting()
            routing.defaultDestination = destination
            #expect(routing.destination(for: url, availableSpaces: [a, b]) == .mostRecentSpace)
            routing.rules = [.init(match: .host, value: url.host!, spaceID: b), .init(value: "https://", spaceID: a)]
            #expect(routing.destination(for: url, availableSpaces: [a, b]) == .space(b))
            #expect(routing.destination(for: url, availableSpaces: [a]) == .space(a))
            #expect(routing.destination(for: url, availableSpaces: []) == .mostRecentSpace)
        }
    }

    @Test("Nonmeeting pages and lookalike hosts retain normal routing", arguments: [
        "https://zoom.us/pricing", "https://around.co/pricing", "https://meet.google.com.example.invalid/a",
        "https://notzoom.us/j/123", "https://app.around.co.example.invalid/room",
        "https://user:secret@meet.google.com/abc", "ftp://meet.google.com/abc"
    ])
    func exclusions(address: String) throws {
        let url = try #require(URL(string: address))
        #expect(!BrowserMeetingLink.matches(url))
        #expect(BrowserLinkRouting().destination(for: url, availableSpaces: []) == .quickWindow)
    }
}
