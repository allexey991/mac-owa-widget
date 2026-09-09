import XCTest
@testable import OWAWidget

/// The rules that decide what a colleague row says. The merged free/busy string is one character
/// per half hour from the window start, so everything here is about indexing into it and finding
/// where the current run ends.
final class ColleagueStatusCalculatorTests: XCTestCase {
    private let windowStart = Date(timeIntervalSince1970: 1_700_000_000)

    private func availability(_ merged: String, email: String = "a@example.com") -> AttendeeAvailability {
        AttendeeAvailability(email: email, mergedFreeBusy: merged, windowStart: windowStart, intervalMinutes: 30)
    }

    private func moment(halfHours: Double) -> Date {
        windowStart.addingTimeInterval(halfHours * 1800)
    }

    func testFreeCellReportsFreeAndEndOfRun() {
        // 00000 22: free until index 5, i.e. 2.5 hours after the window start.
        let status = ColleagueStatusCalculator.status(from: availability("0000022"), now: moment(halfHours: 1.2))

        XCTAssertEqual(status.presence, .free)
        XCTAssertEqual(status.until, moment(halfHours: 5))
    }

    func testBusyRunEndsAtFirstFreeCell() {
        let status = ColleagueStatusCalculator.status(from: availability("2222000"), now: moment(halfHours: 0.1))

        XCTAssertEqual(status.presence, .busy)
        XCTAssertEqual(status.until, moment(halfHours: 4))
    }

    func testTentativeAndOutOfOfficeCodesMapToTheirOwnStates() {
        XCTAssertEqual(ColleagueStatusCalculator.status(from: availability("11"), now: windowStart).presence, .tentative)
        XCTAssertEqual(ColleagueStatusCalculator.status(from: availability("33"), now: windowStart).presence, .away)
    }

    /// Exchange writes `4` for a mailbox whose free/busy this user may not read. Reporting that as
    /// "free" would invite a call to someone whose calendar is not visible at all.
    func testCodeFourIsNoDataRatherThanFree() {
        let status = ColleagueStatusCalculator.status(from: availability("4444"), now: moment(halfHours: 1))

        XCTAssertEqual(status.presence, .noData)
    }

    func testRunReachingEndOfWindowHasNoEndTime() {
        let status = ColleagueStatusCalculator.status(from: availability("0000"), now: moment(halfHours: 2))

        XCTAssertEqual(status.presence, .free)
        XCTAssertNil(status.until, "The grid ends before the state does, so the row must not promise an hour")
    }

    func testMomentOutsideTheWindowIsUnknown() {
        let before = ColleagueStatusCalculator.status(from: availability("0000"), now: windowStart.addingTimeInterval(-60))
        let after = ColleagueStatusCalculator.status(from: availability("0000"), now: moment(halfHours: 4))

        XCTAssertEqual(before.presence, .noData)
        XCTAssertEqual(after.presence, .noData)
    }

    func testEmptyStringIsUnknown() {
        XCTAssertEqual(ColleagueStatusCalculator.status(from: availability(""), now: windowStart).presence, .noData)
    }

    func testStatusesAreKeyedByLowercasedAddress() {
        let rows = [availability("00", email: "Anna.K@Example.com"), availability("22", email: "dmitry@example.com")]

        let statuses = ColleagueStatusCalculator.statuses(from: rows, now: windowStart)

        XCTAssertEqual(statuses["anna.k@example.com"]?.presence, .free)
        XCTAssertEqual(statuses["dmitry@example.com"]?.presence, .busy)
    }
}
