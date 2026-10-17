import Foundation

/// What the feed is served at: `http://127.0.0.1:<port>/<token>/calendar.ics`.
struct ICSFeedRouteConfig: Equatable, Sendable {
    let token: String
    let port: UInt16

    static let fileName = "calendar.ics"

    var path: String { "/\(token)/\(Self.fileName)" }
    var url: URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
}

/// Everything a response needs from the app, captured on the main actor.
struct ICSFeedSnapshot: Sendable {
    let events: [CalendarEvent]
    /// Accounts whose meetings go into the feed (Exchange). EventKit calendars are already in
    /// Calendar.app; serving them again would duplicate every event.
    let feedAccountIDs: Set<UUID>
    /// `false` until the app has loaded either its cache or a sync. An empty calendar served at
    /// that point would make Calendar.app wipe every meeting until its next refresh.
    let hasData: Bool
    let generatedAt: Date
    let timeZone: TimeZone
    let strings: ICSFeedStrings
}

struct ICSHTTPResponse: Equatable, Sendable {
    let status: Int
    let reason: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name] }
}

/// Decides the response to one request. Pure, so every rule is testable without a socket.
enum ICSFeedRouter {
    static let badRequest = plain(400, "Bad Request")

    static func respond(to request: ICSHTTPRequest, config: ICSFeedRouteConfig, snapshot: ICSFeedSnapshot) -> ICSHTTPResponse {
        // Host first: a DNS-rebound web page reaches 127.0.0.1 but sends its own name here, and it
        // must learn nothing else, not even whether the path exists.
        guard let host = request.host?.lowercased(),
              host == "127.0.0.1:\(config.port)" || host == "localhost:\(config.port)"
        else { return plain(403, "Forbidden") }

        let isHead = request.method == "HEAD"
        guard request.method == "GET" || isHead else { return plain(405, "Method Not Allowed") }

        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        guard constantTimeEquals(path, config.path) else { return plain(404, "Not Found") }

        guard snapshot.hasData else { return plain(503, "Service Unavailable") }

        let events = snapshot.events.filter { snapshot.feedAccountIDs.contains($0.accountID) }
        let ics = Data(ICSFeedBuilder.build(
            events: events,
            generatedAt: snapshot.generatedAt,
            timeZone: snapshot.timeZone,
            strings: snapshot.strings
        ).utf8)
        return ICSHTTPResponse(
            status: 200,
            reason: "OK",
            headers: [
                "Content-Type": "text/calendar; charset=utf-8",
                "Cache-Control": "no-cache",
                "Content-Length": String(ics.count),
            ],
            body: isHead ? Data() : ics
        )
    }

    /// Wire format. Every response closes the connection: one request per connection keeps the
    /// listener free of keep-alive bookkeeping, and Calendar polls only every few minutes.
    static func serialize(_ response: ICSHTTPResponse) -> Data {
        var headers = response.headers
        headers["Connection"] = "close"
        if headers["Content-Length"] == nil { headers["Content-Length"] = String(response.body.count) }
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for name in headers.keys.sorted() {
            head += "\(name): \(headers[name]!)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + response.body
    }

    private static func plain(_ status: Int, _ reason: String) -> ICSHTTPResponse {
        ICSHTTPResponse(status: status, reason: reason, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data())
    }

    /// The token is a secret; comparing it with early exit would leak how many leading
    /// characters a guess got right.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
