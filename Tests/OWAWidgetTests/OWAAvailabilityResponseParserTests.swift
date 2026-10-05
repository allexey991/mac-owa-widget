import XCTest
@testable import OWAWidget

/// Free/busy strings must land on the person they belong to, even when Exchange has nothing for
/// one of the mailboxes.
final class OWAAvailabilityResponseParserTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func response(_ items: [[String: Any]]) -> [String: Any] {
        ["Body": ["ResponseClass": "Success", "Responses": items]]
    }

    private func ok(_ merged: String) -> [String: Any] {
        ["ResponseClass": "Success", "CalendarView": ["FreeBusyViewType": "DetailedMerged", "MergedFreeBusy": merged]]
    }

    private let missing: [String: Any] = ["ResponseClass": "Error", "MessageText": "No free/busy"]

    func testMailboxWithoutDataDoesNotShiftTheOthers() {
        let json = response([ok("000"), missing, ok("222")])

        let rows = OWAAvailabilityResponseParser.parse(json, emails: ["a@x.ru", "b@x.ru", "c@x.ru"], windowStart: start)

        // The old zip gave "222" to b.
        XCTAssertEqual(rows.map(\.email), ["a@x.ru", "c@x.ru"])
        XCTAssertEqual(rows.map(\.mergedFreeBusy), ["000", "222"])
        XCTAssertEqual(rows.first?.windowStart, start)
    }

    func testEmptyStringCountsAsNoData() {
        let json = response([ok(""), ok("111")])
        let rows = OWAAvailabilityResponseParser.parse(json, emails: ["a@x.ru", "b@x.ru"], windowStart: start)
        XCTAssertEqual(rows.map(\.email), ["b@x.ru"])
    }

    func testEveryMailboxAnswered() {
        let json = response([ok("0"), ok("2")])
        let rows = OWAAvailabilityResponseParser.parse(json, emails: ["a@x.ru", "b@x.ru"], windowStart: start)
        XCTAssertEqual(rows.map(\.mergedFreeBusy), ["0", "2"])
    }

    func testSingleMailbox() {
        let rows = OWAAvailabilityResponseParser.parse(response([ok("02")]), emails: ["a@x.ru"], windowStart: start)
        XCTAssertEqual(rows.map(\.mergedFreeBusy), ["02"])
    }

    func testUnrecognisedShapeWithMissingDataReturnsNothingRatherThanAGuess() {
        // Strings not grouped per mailbox, and fewer of them than addresses: no safe match.
        let json: [String: Any] = ["A": ["MergedFreeBusy": "000"], "B": ["MergedFreeBusy": "222"]]
        let rows = OWAAvailabilityResponseParser.parse(json, emails: ["a@x.ru", "b@x.ru", "c@x.ru"], windowStart: start)
        XCTAssertTrue(rows.isEmpty)
    }
}
