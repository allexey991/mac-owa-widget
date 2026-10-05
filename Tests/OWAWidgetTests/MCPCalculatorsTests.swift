import XCTest
@testable import OWAWidget

/// Fixed zone and dates so the tests do not depend on the machine or the day they run.
private let moscow = TimeZone(identifier: "Europe/Moscow")!

private func calendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = moscow
    return calendar
}

/// 2026-10-05 is a Monday.
private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar().date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

private func meeting(
    _ id: String,
    _ start: Date,
    _ end: Date,
    response: MeetingResponseType = .accepted,
    allDay: Bool = false,
    title: String? = nil,
    organizer: String? = nil
) -> CalendarEvent {
    CalendarEvent(
        id: id, title: title ?? id, startDate: start, endDate: end, location: nil, bodyPreview: nil,
        joinURL: nil, platform: .generic, isAllDay: allDay, organizer: organizer,
        accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, responseType: response
    )
}

final class ScheduleStatsCalculatorTests: XCTestCase {
    private func stats(_ events: [CalendarEvent], from: Date = date(5, 0), to: Date = date(6, 0),
                       options: ScheduleStatsCalculator.Options = .init()) -> ScheduleStatsCalculator.Result {
        ScheduleStatsCalculator.compute(events: events, range: DateInterval(start: from, end: to), calendar: calendar(), options: options)
    }

    func testParallelMeetingsAreNotDoubleCounted() {
        let result = stats([
            meeting("a", date(5, 10), date(5, 11)),
            meeting("b", date(5, 10, 30), date(5, 11, 30)),
        ])
        XCTAssertEqual(result.meetingCount, 2)
        XCTAssertEqual(result.meetingSeconds, 90 * 60)
        XCTAssertEqual(result.overlapCount, 1)
        XCTAssertEqual(result.overlaps.first?.interval, DateInterval(start: date(5, 10, 30), end: date(5, 11)))
    }

    func testTouchingMeetingsDoNotOverlapButAreBackToBack() {
        let result = stats([
            meeting("a", date(5, 10), date(5, 11)),
            meeting("b", date(5, 11), date(5, 12)),
            meeting("c", date(5, 12, 3), date(5, 13)),
            meeting("d", date(5, 15), date(5, 16)),
        ])
        XCTAssertEqual(result.overlapCount, 0)
        XCTAssertEqual(result.days.first?.backToBackCount, 2)
    }

    func testDeclinedCancelledAndAllDayAreNotBusyTime() {
        var cancelled = meeting("Отменено: c", date(5, 12), date(5, 13))
        cancelled = CalendarEvent(id: "c", title: "x", startDate: date(5, 12), endDate: date(5, 13), location: nil,
                                  bodyPreview: nil, joinURL: nil, platform: .generic, isAllDay: false, organizer: nil,
                                  accountID: cancelled.accountID, isCancelled: true)
        let result = stats([
            meeting("declined", date(5, 10), date(5, 11), response: .declined),
            cancelled,
            meeting("holiday", date(5, 0), date(6, 0), allDay: true),
            meeting("real", date(5, 14), date(5, 15)),
        ])
        XCTAssertEqual(result.meetingCount, 1)
        XCTAssertEqual(result.meetingSeconds, 3600)
        XCTAssertEqual(result.allDayCount, 1)
    }

    func testUnansweredInvitationsCountOnlyWhenAsked() {
        let events = [meeting("invite", date(5, 10), date(5, 11), response: .notResponded)]
        XCTAssertEqual(stats(events).meetingCount, 1)
        var options = ScheduleStatsCalculator.Options()
        options.countUnanswered = false
        XCTAssertEqual(stats(events, options: options).meetingCount, 0)
    }

    func testFocusBlocksInsideWorkingHours() {
        // 09-18 working day; meetings 10-11 and 11:30-16 leave 09-10 (60), 11-11:30 (30), 16-18 (120).
        let result = stats([
            meeting("a", date(5, 10), date(5, 11)),
            meeting("b", date(5, 11, 30), date(5, 16)),
            meeting("evening", date(5, 19), date(5, 20)),
        ])
        XCTAssertEqual(result.focusBlocks.map(\.duration), [3600, 7200])
        XCTAssertEqual(result.days.first?.longestFreeSecondsInWorkHours, 7200)
        XCTAssertEqual(result.workSeconds, 9 * 3600)
        XCTAssertEqual(result.meetingSecondsInWorkHours, 5.5 * 3600)
        XCTAssertEqual(result.meetingSeconds, 6.5 * 3600)
    }

    func testWeekendHasNoWorkingTime() {
        let result = stats([], from: date(10, 0), to: date(12, 0))
        XCTAssertEqual(result.days.count, 2)
        XCTAssertEqual(result.workSeconds, 0)
        XCTAssertTrue(result.focusBlocks.isEmpty)
        XCTAssertEqual(result.meetingShareOfWorkTime, 0)
    }

    func testMeetingAcrossMidnightIsSplitBetweenDays() {
        let result = stats([meeting("night", date(5, 23), date(6, 1))], from: date(5, 0), to: date(7, 0))
        XCTAssertEqual(result.meetingCount, 1)
        XCTAssertEqual(result.days.map(\.meetingSeconds), [3600, 3600])
    }

    func testWorkingHoursFollowTheWallClockOnDSTDays() {
        // Berlin springs forward on 2026-03-29 (a Sunday, so it is listed as a work day here).
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let dayStart = berlin.date(from: DateComponents(year: 2026, month: 3, day: 29))!
        let nineAM = berlin.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 9))!
        var options = ScheduleStatsCalculator.Options()
        options.workDays = [1]

        let result = ScheduleStatsCalculator.compute(
            events: [], range: DateInterval(start: dayStart, end: dayStart.addingTimeInterval(23 * 3600)),
            calendar: berlin, options: options
        )
        XCTAssertEqual(result.focusBlocks.first?.start, nineAM)
        XCTAssertEqual(result.workSeconds, 9 * 3600)
    }

    func testPartialDaysAreFlagged() {
        let result = stats([], from: date(5, 12), to: date(6, 12))
        XCTAssertEqual(result.days.map(\.isPartial), [true, true])
    }
}

final class EventPersonMatcherTests: XCTestCase {
    func testNameInAnyOrderAndScript() throws {
        let matcher = try XCTUnwrap(EventPersonMatcher(query: "Иван Иванов"))
        XCTAssertTrue(matcher.matchesPerson(name: "Иванов Иван Петрович", email: nil))
        XCTAssertFalse(matcher.matchesPerson(name: "Иванов Пётр", email: nil))

        let latin = try XCTUnwrap(EventPersonMatcher(query: "иванов"))
        XCTAssertTrue(latin.matchesPerson(name: "Ivanov Ivan", email: nil))
    }

    func testEmailIsExactIgnoringCase() throws {
        let matcher = try XCTUnwrap(EventPersonMatcher(query: "Ivan.Ivanov@Corp.ru"))
        XCTAssertTrue(matcher.isEmailQuery)
        XCTAssertTrue(matcher.matchesPerson(name: "x", email: "ivan.ivanov@corp.ru"))
        XCTAssertFalse(matcher.matchesPerson(name: "Ivan Ivanov", email: "ivan.ivanov2@corp.ru"))
    }

    func testOrganizerByAddressNeedsAKnownName() throws {
        let matcher = try XCTUnwrap(EventPersonMatcher(query: "ivan@corp.ru"))
        XCTAssertFalse(matcher.matchesOrganizer("Иванов Иван", knownNames: []))
        XCTAssertTrue(matcher.matchesOrganizer("Иванов Иван", knownNames: ["иванов иван"]))
    }

    func testTitleMatchesOnTheSurname() throws {
        let matcher = try XCTUnwrap(EventPersonMatcher(query: "Иван Иванов"))
        XCTAssertTrue(matcher.matchesTitle("1:1 Иванов / Петров"))
        XCTAssertFalse(matcher.matchesTitle("Планирование спринта"))
    }

    func testAttendeeRole() throws {
        let matcher = try XCTUnwrap(EventPersonMatcher(query: "Петров"))
        let attendee = EventAttendee(name: "Петров Пётр", email: "p@corp.ru", kind: .optional, response: .accepted)
        XCTAssertEqual(matcher.match(attendee: attendee), EventPersonMatcher.Match(role: .optional, name: "Петров Пётр", email: "p@corp.ru"))
    }

    func testEmptyQueryIsRejected() {
        XCTAssertNil(EventPersonMatcher(query: "   "))
    }
}

final class NextMeetingGroupPolicyTests: XCTestCase {
    func testUpcomingGroupHasNoHorizonAndSkipsCurrent() {
        let now = date(5, 22)
        let events = [
            meeting("running", date(5, 21, 30), date(5, 22, 30)),
            meeting("tomorrow-a", date(6, 9), date(6, 10)),
            meeting("tomorrow-b", date(6, 9, 4), date(6, 10)),
            meeting("tomorrow-c", date(6, 9, 30), date(6, 10)),
        ]
        XCTAssertEqual(NextMeetingGroupPolicy.upcomingGroup(from: events, now: now).map(\.id), ["tomorrow-a", "tomorrow-b"])
        // The banner keeps its 30-minute horizon and shows the running meeting.
        XCTAssertEqual(NextMeetingGroupPolicy.bannerGroup(from: events, now: now).map(\.id), ["running"])
    }
}

final class MCPSupportTests: XCTestCase {
    func testDateCoderReadsAndWritesTheDisplayZone() {
        let coder = MCPDateCoder(timeZone: moscow)
        XCTAssertEqual(coder.string(date(5, 10)), "2026-10-05T10:00:00+03:00")
        XCTAssertEqual(coder.parse("2026-10-05", as: .start), date(5, 0))
        XCTAssertEqual(coder.parse("2026-10-05", as: .end), date(6, 0))
        XCTAssertEqual(coder.parse("2026-10-05T10:30", as: .start), date(5, 10, 30))
        XCTAssertEqual(coder.parse("2026-10-05T07:30:00Z", as: .start), date(5, 10, 30))
        XCTAssertNil(coder.parse("next tuesday", as: .start))
        XCTAssertEqual(MCPDateCoder.minuteOfDay("09:30"), 570)
        XCTAssertNil(MCPDateCoder.minuteOfDay("25:00"))
    }

    func testShortEventIDsAreStableAndResolvable() {
        let longID = "AAMkAGI2TG93AAA=" + String(repeating: "x", count: 120)
        let event = meeting(longID, date(5, 10), date(5, 11))
        let short = MCPEventID.short(longID)
        XCTAssertEqual(short.count, 12)
        XCTAssertEqual(short, MCPEventID.short(longID))
        XCTAssertEqual(MCPEventID.resolve(short, in: [event])?.id, longID)
        XCTAssertEqual(MCPEventID.resolve(longID, in: [event])?.id, longID)
        XCTAssertNil(MCPEventID.resolve("000000000000", in: [event]))
    }

    func testTokenBucketRefills() {
        let start = date(5, 10)
        var bucket = MCPTokenBucket(capacity: 2, perMinute: 60, now: start)
        XCTAssertTrue(bucket.take(now: start))
        XCTAssertTrue(bucket.take(now: start))
        XCTAssertFalse(bucket.take(now: start))
        XCTAssertTrue(bucket.take(now: start.addingTimeInterval(1)))
    }
}
