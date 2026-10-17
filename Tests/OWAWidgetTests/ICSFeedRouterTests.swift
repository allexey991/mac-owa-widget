import XCTest
@testable import OWAWidget

/// Who gets the feed and what they get. The feed holds meetings with attendees, and 127.0.0.1 is
/// reachable by every local process and, through DNS rebinding, by web pages — hence the secret
/// path and the Host check.
final class ICSFeedRouterTests: XCTestCase {
    private let token = "0123456789abcdef0123456789abcdef"
    private let owaAccount = UUID()
    private let eventKitAccount = UUID()
    private lazy var config = ICSFeedRouteConfig(token: token, port: 47318)

    private func event(_ title: String, account: UUID) -> CalendarEvent {
        CalendarEvent(
            id: title,
            title: title,
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_003_600),
            location: nil,
            bodyPreview: nil,
            joinURL: nil,
            platform: .generic,
            isAllDay: false,
            organizer: nil,
            accountID: account
        )
    }

    private func snapshot(hasData: Bool = true) -> ICSFeedSnapshot {
        ICSFeedSnapshot(
            events: [event("Exchange meeting", account: owaAccount), event("iCloud dinner", account: eventKitAccount)],
            feedAccountIDs: [owaAccount],
            hasData: hasData,
            generatedAt: Date(timeIntervalSince1970: 1_799_000_000),
            timeZone: TimeZone(identifier: "UTC")!,
            strings: ICSFeedStrings(cancelledPrefix: "", declinedPrefix: "", organizerLabel: "O", attendeesLabel: "A")
        )
    }

    private func request(
        method: String = "GET",
        path: String? = nil,
        host: String? = "127.0.0.1:47318"
    ) -> ICSHTTPRequest {
        ICSHTTPRequest(method: method, path: path ?? "/\(token)/calendar.ics", host: host, userAgent: nil)
    }

    private func respond(_ request: ICSHTTPRequest, hasData: Bool = true) -> ICSHTTPResponse {
        ICSFeedRouter.respond(to: request, config: config, snapshot: snapshot(hasData: hasData))
    }

    private func body(_ response: ICSHTTPResponse) -> String {
        String(decoding: response.body, as: UTF8.self)
    }

    func testValidRequestGetsCalendar() {
        let response = respond(request())

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.header("Content-Type"), "text/calendar; charset=utf-8")
        XCTAssertEqual(response.header("Cache-Control"), "no-cache")
        XCTAssertTrue(body(response).hasPrefix("BEGIN:VCALENDAR"))
    }

    func testFeedContainsOnlyFeedAccounts() {
        let text = body(respond(request()))

        XCTAssertTrue(text.contains("SUMMARY:Exchange meeting"))
        XCTAssertFalse(text.contains("iCloud dinner"))
    }

    func testLocalhostHostIsAccepted() {
        XCTAssertEqual(respond(request(host: "localhost:47318")).status, 200)
    }

    func testQueryStringIsIgnored() {
        XCTAssertEqual(respond(request(path: "/\(token)/calendar.ics?refresh=1")).status, 200)
    }

    func testWrongTokenIsNotFound() {
        XCTAssertEqual(respond(request(path: "/ffffffffffffffffffffffffffffffff/calendar.ics")).status, 404)
        XCTAssertEqual(respond(request(path: "/")).status, 404)
        XCTAssertEqual(respond(request(path: "/\(token)")).status, 404)
    }

    func testForeignHostIsForbidden() {
        // A DNS-rebound page reaches 127.0.0.1 but still sends its own name as Host.
        XCTAssertEqual(respond(request(host: "evil.example:47318")).status, 403)
        XCTAssertEqual(respond(request(host: "127.0.0.1:9999")).status, 403)
        XCTAssertEqual(respond(request(host: nil)).status, 403)
    }

    func testOtherMethodsAreNotAllowed() {
        XCTAssertEqual(respond(request(method: "POST")).status, 405)
    }

    func testNoDataYetIsServiceUnavailable() {
        // An empty calendar would make Calendar.app wipe every meeting until the next refresh.
        XCTAssertEqual(respond(request(), hasData: false).status, 503)
    }

    func testHeadHasLengthButNoBody() {
        let get = respond(request())
        let head = respond(request(method: "HEAD"))

        XCTAssertEqual(head.status, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertEqual(head.header("Content-Length"), String(get.body.count))
    }

    func testSerializedResponseClosesConnection() {
        let text = String(decoding: ICSFeedRouter.serialize(respond(request(path: "/"))), as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(text.contains("\r\nConnection: close\r\n"))
        XCTAssertTrue(text.contains("\r\nContent-Length: "))
        XCTAssertTrue(text.contains("\r\n\r\n"))
    }

    func testBadRequestResponse() {
        XCTAssertEqual(ICSFeedRouter.badRequest.status, 400)
    }
}
