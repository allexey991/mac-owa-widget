import XCTest
@testable import OWAWidget

/// When the section spends a request, and how much it trusts what it already has.
final class ColleagueRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let ttl: TimeInterval = 300

    func testFirstOpeningRefreshes() {
        XCTAssertTrue(ColleagueRefreshPolicy.shouldRefresh(
            lastSuccessAt: nil, now: now, ttl: ttl, isRefreshing: false, hasColleagues: true
        ))
    }

    /// Reopening the popover a dozen times in a row must stay one request.
    func testRecentSuccessIsReused() {
        XCTAssertFalse(ColleagueRefreshPolicy.shouldRefresh(
            lastSuccessAt: now.addingTimeInterval(-60), now: now, ttl: ttl, isRefreshing: false, hasColleagues: true
        ))
    }

    func testDataOlderThanTheCacheRefreshes() {
        XCTAssertTrue(ColleagueRefreshPolicy.shouldRefresh(
            lastSuccessAt: now.addingTimeInterval(-301), now: now, ttl: ttl, isRefreshing: false, hasColleagues: true
        ))
    }

    func testNoRequestWhileOneIsInFlightOrTheListIsEmpty() {
        XCTAssertFalse(ColleagueRefreshPolicy.shouldRefresh(
            lastSuccessAt: nil, now: now, ttl: ttl, isRefreshing: true, hasColleagues: true
        ))
        XCTAssertFalse(ColleagueRefreshPolicy.shouldRefresh(
            lastSuccessAt: nil, now: now, ttl: ttl, isRefreshing: false, hasColleagues: false
        ))
    }

    /// A grid fetched yesterday describes yesterday, however recently it arrived.
    func testWindowFromAnotherDayIsNotUsable() {
        let calendar = AppTimeZone.calendar
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!

        XCTAssertFalse(ColleagueRefreshPolicy.isWindowUsable(windowStart: yesterday, now: now, calendar: calendar))
        XCTAssertTrue(ColleagueRefreshPolicy.isWindowUsable(windowStart: calendar.startOfDay(for: now), now: now, calendar: calendar))
        XCTAssertFalse(ColleagueRefreshPolicy.isWindowUsable(windowStart: nil, now: now, calendar: calendar))
    }

    func testFreshnessFollowsTheLastAttempt() {
        let success = now.addingTimeInterval(-120)

        XCTAssertEqual(
            ColleagueRefreshPolicy.freshness(lastSuccessAt: success, lastAttemptFailed: false, windowUsable: true),
            .fresh
        )
        XCTAssertEqual(
            ColleagueRefreshPolicy.freshness(lastSuccessAt: success, lastAttemptFailed: true, windowUsable: true),
            .stale(since: success)
        )
        XCTAssertEqual(
            ColleagueRefreshPolicy.freshness(lastSuccessAt: success, lastAttemptFailed: false, windowUsable: false),
            .none
        )
        XCTAssertEqual(
            ColleagueRefreshPolicy.freshness(lastSuccessAt: nil, lastAttemptFailed: false, windowUsable: true),
            .none
        )
    }

    func testRequestWindowCoversAWeekFromMidnight() {
        let calendar = AppTimeZone.calendar
        let bounds = ColleagueAvailabilityWindow.bounds(now: now, calendar: calendar)

        XCTAssertEqual(bounds.start, calendar.startOfDay(for: now))
        XCTAssertEqual(calendar.dateComponents([.day], from: bounds.start, to: bounds.end).day, 7)
    }
}
