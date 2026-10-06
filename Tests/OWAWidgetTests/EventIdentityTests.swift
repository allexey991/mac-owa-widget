import XCTest
@testable import OWAWidget

/// A meeting's identity across mailboxes and calendar systems: the iCalendar UID and the
/// recurring series, from Exchange and from EventKit.
final class EventIdentityTests: XCTestCase {
    // Real values from an Exchange mailbox: the series id from GetCalendarView and the UID of
    // the 6 October 2026 occurrence from GetCalendarEvent (07EA0A06 = 2026-10-06).
    private let seriesHex = "040000008200E00074C5B7101A82E00800000000" + "36FC3397C23ADD01000000000000000010000000EA9C69D732B2134F9FFCD7CC81FB2D49"
    private let occurrenceHex = "040000008200E00074C5B7101A82E00807EA0A06" + "36FC3397C23ADD01000000000000000010000000EA9C69D732B2134F9FFCD7CC81FB2D49"

    /// A Global Object ID wrapping an iCalendar UID from another calendar system.
    private func vCalGlobalObjectID(_ uid: String) -> String {
        let data = Array("vCal-Uid".utf8) + [0x01, 0x00, 0x00, 0x00] + Array(uid.utf8) + [0x00]
        let size = UInt32(data.count)
        var bytes: [UInt8] = [0x04, 0x00, 0x00, 0x00, 0x82, 0x00, 0xE0, 0x00, 0x74, 0xC5, 0xB7, 0x10, 0x1A, 0x82, 0xE0, 0x08]
        bytes += [0x07, 0xEA, 0x0A, 0x06] + Array(repeating: 0, count: 16)
        bytes += [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)]
        bytes += data
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Global Object ID

    func testOccurrenceUIDIsTheSeriesUID() {
        XCTAssertEqual(ExchangeGlobalObjectID.icalUID(fromHex: occurrenceHex), seriesHex)
        XCTAssertEqual(ExchangeGlobalObjectID.icalUID(fromHex: seriesHex), seriesHex)
        XCTAssertEqual(ExchangeGlobalObjectID.icalUID(fromHex: occurrenceHex.lowercased()), seriesHex)
    }

    func testMeetingFromAnotherCalendarSystemKeepsItsOwnUID() {
        XCTAssertEqual(
            ExchangeGlobalObjectID.icalUID(fromHex: vCalGlobalObjectID("7kukuqrfedvc8@google.com")),
            "7kukuqrfedvc8@google.com"
        )
    }

    func testValuesThatAreNotGlobalObjectIDsPassThrough() {
        XCTAssertEqual(ExchangeGlobalObjectID.icalUID(fromHex: "abc@example.com"), "abc@example.com")
        XCTAssertEqual(ExchangeGlobalObjectID.icalUID(fromHex: "0400"), "0400")
        XCTAssertNil(ExchangeGlobalObjectID.icalUID(fromHex: "  "))
    }

    func testUIDIsReadFromTheMeetingDetails() {
        let json = """
        {"Body":{"ResponseMessages":{"Items":[{"Items":[{"__type":"CalendarItem:#Exchange",
        "ItemId":{"Id":"AAMk"},"UID":"\(occurrenceHex)","Subject":"x"}]}]}}}
        """
        XCTAssertEqual(OWACalendarEventUIDParser.icalUID(fromJSONData: Data(json.utf8)), seriesHex)
        XCTAssertNil(OWACalendarEventUIDParser.icalUID(fromJSONData: Data(#"{"Body":{}}"#.utf8)))
    }

    // MARK: - Exchange items

    private func item(_ json: String) throws -> OWACalendarItem {
        try JSONDecoder().decode(OWACalendarItem.self, from: Data(json.utf8))
    }

    func testOccurrenceGetsSeriesAndUIDFromTheSyncAlone() throws {
        let occurrence = try item(#"{"CalendarItemType":"Occurrence","IsRecurring":true,"SeriesId":"\#(seriesHex)"}"#)
        let identity = OWACalendarProvider.identity(of: occurrence)
        XCTAssertEqual(identity.seriesID, seriesHex)
        XCTAssertEqual(identity.icalUID, seriesHex)
        XCTAssertTrue(identity.isRecurring)
    }

    func testOneOffMeetingHasNoIdentityUntilItsDetailsLoad() throws {
        let single = try item(#"{"CalendarItemType":"Single","IsRecurring":false}"#)
        let identity = OWACalendarProvider.identity(of: single)
        XCTAssertNil(identity.icalUID)
        XCTAssertNil(identity.seriesID)
        XCTAssertFalse(identity.isRecurring)
    }

    // MARK: - EventKit

    private func snapshot(recurring: Bool, external: String? = "abc@google.com") -> EventKitEventSnapshot {
        EventKitEventSnapshot(
            eventIdentifier: "cal:event",
            externalIdentifier: external,
            calendarIdentifier: "cal",
            calendarTitle: "Work",
            title: "Sync",
            startDate: Date(timeIntervalSinceReferenceDate: 1_000_000),
            endDate: Date(timeIntervalSinceReferenceDate: 1_001_800),
            isAllDay: false,
            occurrenceDate: recurring ? Date(timeIntervalSinceReferenceDate: 1_000_000) : nil,
            hasRecurrenceRules: recurring,
            status: .confirmed,
            url: nil,
            location: nil,
            notes: nil,
            organizer: nil,
            attendees: []
        )
    }

    func testEventKitUsesTheServerIdentifier() throws {
        let mapper = EventKitEventMapper()
        let recurring = try XCTUnwrap(mapper.map(snapshot(recurring: true), accountID: UUID()))
        XCTAssertEqual(recurring.icalUID, "abc@google.com")
        XCTAssertEqual(recurring.seriesID, "abc@google.com")
        XCTAssertTrue(recurring.isRecurring)

        let single = try XCTUnwrap(mapper.map(snapshot(recurring: false), accountID: UUID()))
        XCTAssertEqual(single.icalUID, "abc@google.com")
        XCTAssertNil(single.seriesID)
        XCTAssertFalse(single.isRecurring)

        let local = try XCTUnwrap(mapper.map(snapshot(recurring: true, external: nil), accountID: UUID()))
        XCTAssertNil(local.icalUID)
        XCTAssertEqual(local.seriesID, "cal:event")
    }

    // MARK: - Model

    func testIdentitySurvivesTheDiskCacheAndOldCachesStillLoad() throws {
        let event = CalendarEvent(
            id: "a", title: "t", startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 1800),
            location: nil, bodyPreview: nil, joinURL: nil, platform: .generic, isAllDay: false, organizer: nil,
            accountID: UUID(), icalUID: "uid", seriesID: "series"
        )
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded.icalUID, "uid")
        XCTAssertEqual(decoded.seriesID, "series")
        XCTAssertTrue(decoded.isRecurring)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        legacy["icalUID"] = nil
        legacy["seriesID"] = nil
        legacy["isRecurring"] = nil
        let old = try JSONDecoder().decode(CalendarEvent.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.icalUID)
        XCTAssertFalse(old.isRecurring)
    }

    func testDetailsFillInTheUIDAndKeepTheSeries() {
        let event = CalendarEvent(
            id: "a", title: "t", startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 1800),
            location: nil, bodyPreview: nil, joinURL: nil, platform: .generic, isAllDay: false, organizer: nil,
            accountID: UUID(), seriesID: "series"
        )
        let loaded = event.withDetails(CalendarEventDetails(attendees: [], icalUID: "uid"))
        XCTAssertEqual(loaded.icalUID, "uid")
        XCTAssertEqual(loaded.seriesID, "series")
        XCTAssertEqual(loaded.withResponseType(.accepted).icalUID, "uid")
        // Details without a UID do not erase a known one.
        XCTAssertEqual(loaded.withDetails(CalendarEventDetails(attendees: [])).icalUID, "uid")
    }
}
