import XCTest
@testable import OWAWidget

/// The ICS text Calendar.app subscribes to. Calendar replaces the whole calendar on every refresh,
/// so what matters is that each occurrence keeps a stable, unique UID and that the text survives
/// RFC 5545 encoding (escaping, folding, CRLF) without corrupting non-ASCII titles.
final class ICSFeedBuilderTests: XCTestCase {
    private let accountID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let generatedAt = ISO8601DateFormatter().date(from: "2026-10-18T09:00:00Z")!
    private let moscow = TimeZone(identifier: "Europe/Moscow")!
    private let strings = ICSFeedStrings(
        cancelledPrefix: "Cancelled: ",
        declinedPrefix: "Declined: ",
        organizerLabel: "Organizer",
        attendeesLabel: "Attendees"
    )

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func event(
        id: String = "AAMk-1",
        title: String = "Planning",
        start: String = "2026-10-20T10:00:00Z",
        end: String = "2026-10-20T11:00:00Z",
        location: String? = nil,
        bodyPreview: String? = nil,
        joinURL: URL? = nil,
        isAllDay: Bool = false,
        organizer: String? = nil,
        attendees: [String] = [],
        isCancelled: Bool = false,
        categories: [String] = [],
        responseType: MeetingResponseType = .accepted,
        seriesID: String? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: title,
            startDate: date(start),
            endDate: date(end),
            location: location,
            bodyPreview: bodyPreview,
            joinURL: joinURL,
            platform: .generic,
            isAllDay: isAllDay,
            organizer: organizer,
            attendees: attendees,
            accountID: accountID,
            isCancelled: isCancelled,
            categories: categories,
            responseType: responseType,
            seriesID: seriesID
        )
    }

    private func build(_ events: [CalendarEvent]) -> String {
        ICSFeedBuilder.build(events: events, generatedAt: generatedAt, timeZone: moscow, strings: strings)
    }

    /// Unfolded content lines, so assertions are not tied to where folding happened.
    private func lines(_ ics: String) -> [String] {
        ics.replacingOccurrences(of: "\r\n ", with: "")
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
    }

    private func vevents(_ ics: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String]?
        for line in lines(ics) {
            if line == "BEGIN:VEVENT" { current = [] }
            else if line == "END:VEVENT" { if let c = current { result.append(c) }; current = nil }
            else { current?.append(line) }
        }
        return result
    }

    private func value(_ name: String, in props: [String]) -> String? {
        props.first { $0.hasPrefix(name + ":") || $0.hasPrefix(name + ";") }
            .map { String($0[$0.index(after: $0.firstIndex(of: ":")!)...]) }
    }

    // MARK: - Calendar envelope

    func testEnvelopeDeclaresCalendarNameAndRefreshInterval() {
        let all = lines(build([]))

        XCTAssertEqual(all.first, "BEGIN:VCALENDAR")
        XCTAssertEqual(all.last, "END:VCALENDAR")
        XCTAssertTrue(all.contains("VERSION:2.0"))
        XCTAssertTrue(all.contains("X-WR-CALNAME:OWA Widget"))
        XCTAssertTrue(all.contains("REFRESH-INTERVAL;VALUE=DURATION:PT5M"))
        XCTAssertTrue(all.contains("X-PUBLISHED-TTL:PT5M"))
    }

    func testEveryLineEndsWithCRLF() {
        let ics = build([event(title: "A"), event(id: "AAMk-2", title: "B")])

        XCTAssertTrue(ics.hasSuffix("\r\n"))
        XCTAssertFalse(ics.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertFalse(ics.replacingOccurrences(of: "\r\n", with: "").contains("\r"))
    }

    // MARK: - Times

    func testTimedEventUsesUTC() {
        let props = vevents(build([event(start: "2026-10-20T10:00:00Z", end: "2026-10-20T11:30:00Z")]))[0]

        XCTAssertTrue(props.contains("DTSTART:20261020T100000Z"))
        XCTAssertTrue(props.contains("DTEND:20261020T113000Z"))
        XCTAssertTrue(props.contains("DTSTAMP:20261018T090000Z"))
    }

    func testAllDayEventUsesDatesInDisplayTimeZone() {
        // Midnight to midnight in Moscow is 21:00Z the day before: a UTC date would be off by one.
        let allDay = event(start: "2026-10-19T21:00:00Z", end: "2026-10-20T21:00:00Z", isAllDay: true)
        let props = vevents(build([allDay]))[0]

        XCTAssertTrue(props.contains("DTSTART;VALUE=DATE:20261020"))
        XCTAssertTrue(props.contains("DTEND;VALUE=DATE:20261021"))
    }

    // MARK: - Identity

    func testOccurrencesOfOneSeriesGetDistinctStableUIDs() {
        let first = event(id: "occ-1", start: "2026-10-20T10:00:00Z", end: "2026-10-20T11:00:00Z", seriesID: "S")
        let second = event(id: "occ-2", start: "2026-10-27T10:00:00Z", end: "2026-10-27T11:00:00Z", seriesID: "S")

        let uids = vevents(build([first, second])).map { value("UID", in: $0) }
        let again = vevents(build([first, second])).map { value("UID", in: $0) }

        XCTAssertEqual(Set(uids.compactMap { $0 }).count, 2)
        XCTAssertEqual(uids, again)
    }

    func testUIDDoesNotExposeExchangeItemID() {
        let uid = value("UID", in: vevents(build([event(id: "AAMkSecretItemId")]))[0])!

        XCTAssertFalse(uid.contains("AAMkSecretItemId"))
        XCTAssertTrue(uid.hasSuffix("@owawidget"))
    }

    // MARK: - Fields

    func testOptionalFieldsAreOmittedWhenEmpty() {
        let props = vevents(build([event(location: nil, bodyPreview: nil, joinURL: nil, organizer: nil)]))[0]

        for name in ["LOCATION", "URL", "DESCRIPTION", "CATEGORIES", "ORGANIZER"] {
            XCTAssertNil(value(name, in: props), "\(name) should be omitted")
        }
    }

    func testJoinURLGoesToURLAndFirstDescriptionLine() {
        let link = URL(string: "https://teams.microsoft.com/l/meetup-join/abc")!
        let props = vevents(build([event(location: "Room 1", bodyPreview: "Agenda", joinURL: link)]))[0]

        XCTAssertEqual(value("URL", in: props), link.absoluteString)
        XCTAssertEqual(value("LOCATION", in: props), "Room 1")
        XCTAssertTrue(value("DESCRIPTION", in: props)!.hasPrefix(link.absoluteString + "\\n"))
    }

    func testDescriptionListsOrganizerAndAttendees() {
        let props = vevents(build([event(organizer: "Ivanov Ivan", attendees: ["Petrov", "Sidorov"])]))[0]
        let description = value("DESCRIPTION", in: props)!

        XCTAssertTrue(description.contains("Organizer: Ivanov Ivan"))
        XCTAssertTrue(description.contains("Attendees: Petrov\\, Sidorov"))
    }

    func testCategoriesAreCommaSeparatedAndEscaped() {
        let props = vevents(build([event(categories: ["Red", "A,B"])]))[0]

        XCTAssertEqual(value("CATEGORIES", in: props), "Red,A\\,B")
    }

    // MARK: - Status

    func testAcceptedMeetingIsConfirmedAndBusy() {
        let props = vevents(build([event(responseType: .accepted)]))[0]

        XCTAssertEqual(value("STATUS", in: props), "CONFIRMED")
        XCTAssertEqual(value("TRANSP", in: props), "OPAQUE")
        XCTAssertEqual(value("SUMMARY", in: props), "Planning")
    }

    func testTentativeMeetingIsTentative() {
        let props = vevents(build([event(responseType: .tentative)]))[0]

        XCTAssertEqual(value("STATUS", in: props), "TENTATIVE")
        XCTAssertEqual(value("TRANSP", in: props), "OPAQUE")
    }

    func testCancelledMeetingIsMarkedAndFree() {
        let props = vevents(build([event(isCancelled: true)]))[0]

        XCTAssertEqual(value("STATUS", in: props), "CANCELLED")
        XCTAssertEqual(value("TRANSP", in: props), "TRANSPARENT")
        XCTAssertEqual(value("SUMMARY", in: props), "Cancelled: Planning")
    }

    func testDeclinedMeetingIsMarkedAndFreeButNotCancelled() {
        let props = vevents(build([event(responseType: .declined)]))[0]

        XCTAssertEqual(value("STATUS", in: props), "CONFIRMED")
        XCTAssertEqual(value("TRANSP", in: props), "TRANSPARENT")
        XCTAssertEqual(value("SUMMARY", in: props), "Declined: Planning")
    }

    func testNoAlarmsAreEmitted() {
        XCTAssertFalse(build([event()]).contains("BEGIN:VALARM"))
    }

    // MARK: - Encoding

    func testTextIsEscaped() {
        XCTAssertEqual(ICSFeedBuilder.escapeText("a\\b;c,d\ne\r\nf"), "a\\\\b\\;c\\,d\\ne\\nf")
    }

    func testLongCyrillicLineIsFoldedWithoutSplittingCharacters() {
        let title = String(repeating: "Встреча по планированию 🗓 ", count: 8)
        let ics = build([event(title: title)])

        for physical in ics.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(physical.utf8.count, 75, physical)
        }
        // Folding inside a multi-byte character would not round-trip through UTF-8 decoding.
        XCTAssertEqual(String(decoding: Data(ics.utf8), as: UTF8.self), ics)
        XCTAssertEqual(value("SUMMARY", in: vevents(ics)[0]), title)
    }
}
