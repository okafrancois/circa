import Foundation
import CoreFoundation

/// Optional, memory-only enrichment. The agenda remains the authority for row membership.
public enum BrowserCalendarBootstrap {
    public static func meetingURL(_ value: String) -> URL? {
        guard value.utf8.count <= 4096, !value.contains("\\"),
              let parts = URLComponents(string: value), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let host = parts.host, host == host.lowercased(), let url = parts.url else { return nil }
        let path = parts.percentEncodedPath
        let pattern: String
        if host == "meet.google.com" {
            pattern = #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}$"#
        } else if host == "zoom.us" || host.range(of: #"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+zoom\.us$"#, options: .regularExpression) != nil {
            pattern = #"^/j/[0-9]{9,11}/?$"#
        } else if host == "teams.microsoft.com" {
            pattern = #"^/l/meetup-join/19(?:%3[Aa]|:)meeting_[A-Za-z0-9_%=-]+(?:%40|@)thread\.v2/0$"#
        } else { return nil }
        guard path.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return url
    }

    public static func occurrenceID(_ eid: String) -> String? {
        var encoded = eid.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8),
              let space = decoded.firstIndex(of: " "), space != decoded.startIndex,
              decoded.index(after: space) < decoded.endIndex else { return nil }
        return String(decoded[..<space])
    }

    public static func enrich(_ agenda: BrowserCalendarWebAgenda, json: Data) -> BrowserCalendarWebAgenda {
        guard json.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: json),
              let groups = at(root, [39, 1]) as? [Any], groups.count <= 200 else { return agenda }
        let primary = groups.filter { at($0, [0]) as? String == agenda.binding }
        guard primary.count == 1, let rows = at(primary[0], [1]) as? [Any], rows.count <= 2000 else { return agenda }
        var tuples: [String: (Date, Date, URL?)] = [:]
        var ids = Set<String>()
        for row in rows {
            guard let tuple = at(row, [3]) as? [Any], tuple.count > 57,
                  let id = tuple[0] as? String, !id.isEmpty, ids.insert(id).inserted else { return agenda }
            guard tuple[15] is NSNull else { continue }
            guard let start = epoch(at(tuple, [35, 1, 0])), let end = epoch(at(tuple, [36, 1, 0])),
                  end > start else { return agenda }
            let join = (at(tuple, [57, 0, 0, 1]) as? String).flatMap(meetingURL)
            tuples[id] = (start, end, join)
        }
        let events = agenda.events.map { event -> BrowserCalendarWebEvent in
            guard let id = occurrenceID(event.id), let (start, end, join) = tuples[id] else { return event }
            return .init(id: event.id, title: event.title, start: start, end: end, joinURL: join)
        }
        return .init(events: events.sorted { $0.start < $1.start }, fetchedAt: agenda.fetchedAt, day: agenda.day, timeZone: agenda.timeZone, binding: agenda.binding)
    }
    private static func at(_ value: Any, _ indices: [Int]) -> Any? {
        var cursor: Any = value
        for index in indices {
            guard let array = cursor as? [Any], array.indices.contains(index) else { return nil }
            cursor = array[index]
        }
        return cursor
    }
    private static func epoch(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue / 1000
        guard seconds.isFinite, seconds >= 0, seconds < 253402300800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
