import XCTest
@testable import OWAWidget

/// Which meeting a stretch of time was: the scores behind `match_event`.
final class MeetingMatchScorerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minutes: Int) -> Date { base.addingTimeInterval(TimeInterval(minutes * 60)) }

    private func meeting(_ title: String, from: Int, to: Int, organizer: String? = nil, response: MeetingResponseType = .accepted) -> CalendarEvent {
        CalendarEvent(
            id: title, title: title, startDate: at(from), endDate: at(to), location: nil, bodyPreview: nil,
            joinURL: nil, platform: .generic, isAllDay: false, organizer: organizer, accountID: UUID(),
            responseType: response
        )
    }

    func testRecordingThatStartedLateStillMatchesItsMeeting() {
        // A call recorded 15:01–16:02 against a 15:00–16:00 meeting and a parallel 15:30–16:00 one.
        let planned = meeting("РГ", from: 0, to: 60)
        let parallel = meeting("Интеграция", from: 30, to: 60)
        let recorded = (start: at(1), end: at(62))

        let plannedScore = MeetingMatchScorer.timeScore(event: planned, start: recorded.start, end: recorded.end)
        let parallelScore = MeetingMatchScorer.timeScore(event: parallel, start: recorded.start, end: recorded.end)

        XCTAssertGreaterThan(plannedScore, 0.9)
        XCTAssertGreaterThan(plannedScore, parallelScore + 0.2)
        XCTAssertEqual(MeetingMatchScorer.overlapMinutes(event: planned, start: recorded.start, end: recorded.end), 59)
    }

    func testAMomentMatchesTheMeetingItFallsIn() {
        let inside = MeetingMatchScorer.timeScore(event: meeting("a", from: 0, to: 60), start: at(30), end: at(30))
        let outside = MeetingMatchScorer.timeScore(event: meeting("b", from: 40, to: 90), start: at(30), end: at(30))
        XCTAssertGreaterThan(inside, outside)
    }

    func testCandidatesStayWithinTheSlack() {
        let events = [
            meeting("before", from: -60, to: -20),
            meeting("just before", from: -40, to: -10),
            meeting("long", from: -600, to: 600),
            meeting("after", from: 80, to: 120),
        ]
        let found = MeetingMatchScorer.candidates(events, start: at(0), end: at(60)).map(\.title)
        // Within 15 minutes either side of 0–60.
        XCTAssertEqual(found, ["just before", "long"])
    }

    func testParticipantsMatchInAnyOrderScriptOrByAddress() {
        let attendees = [
            EventAttendee(name: "Иванов Иван Иванович", email: "IIvanov@corp.ru", kind: .required, response: .accepted),
            EventAttendee(name: "Petrova Anna", email: "apetrova@corp.ru", kind: .optional, response: .accepted),
        ]
        let match = MeetingMatchScorer.matchParticipants(
            ["Иван Иванов", "Петрова Анна", "iivanov@corp.ru", "Сидоров", "Козлов Пётр"],
            attendees: attendees,
            organizer: "Козлов Пётр Петрович"
        )
        XCTAssertEqual(match.matched, ["Иван Иванов", "Петрова Анна", "iivanov@corp.ru", "Козлов Пётр"])
        XCTAssertEqual(match.unmatched, ["Сидоров"])
    }

    func testTitleHintCountsItsWords() {
        XCTAssertEqual(MeetingMatchScorer.titleScore(hint: "агент взыскания", title: "Агент Взыскания: вопросы от ДПА"), 1)
        XCTAssertEqual(MeetingMatchScorer.titleScore(hint: "агент релиз", title: "Агент Взыскания"), 0.5)
        XCTAssertNil(MeetingMatchScorer.titleScore(hint: "и в", title: "x"))
    }

    func testDeclinedAndCancelledMeetingsRankLower() {
        let components = MeetingMatchScorer.Components(time: 1, participants: nil, title: nil)
        let accepted = MeetingMatchScorer.score(components, event: meeting("a", from: 0, to: 60))
        let declined = MeetingMatchScorer.score(components, event: meeting("b", from: 0, to: 60, response: .declined))
        XCTAssertEqual(accepted, 1)
        XCTAssertLessThan(declined, accepted)
    }

    func testCloseScoresAreAmbiguous() {
        XCTAssertEqual(MeetingMatchScorer.confidence(scores: [0.9, 0.4]).confidence, .high)
        XCTAssertFalse(MeetingMatchScorer.confidence(scores: [0.9, 0.4]).ambiguous)
        let tie = MeetingMatchScorer.confidence(scores: [0.9, 0.85])
        XCTAssertTrue(tie.ambiguous)
        XCTAssertEqual(tie.confidence, .medium)
        XCTAssertEqual(MeetingMatchScorer.confidence(scores: [0.3]).confidence, .low)
    }
}
