import Foundation

/// Which calendar meeting a stretch of time was: a call recording, a note, "what was I in at
/// 15:00". Scores each candidate by time, by the people who were there and by a title hint;
/// pure, so `match_event` and its tests share it.
enum MeetingMatchScorer {
    /// Candidates are meetings within this distance of the interval: a call often starts a few
    /// minutes late and overruns.
    static let slack: TimeInterval = 15 * 60
    /// Start offsets beyond this no longer count as "started together".
    static let startTolerance: TimeInterval = 30 * 60

    struct Components: Equatable {
        /// 0...1: how much of the shorter of the two intervals they share, and how close they start.
        let time: Double
        /// 0...1, `nil` when no participants were given or the attendees are unknown.
        let participants: Double?
        /// 0...1, `nil` without a title hint.
        let title: Double?
    }

    struct ParticipantMatch: Equatable {
        let matched: [String]
        let unmatched: [String]
    }

    enum Confidence: String {
        case high, medium, low
    }

    /// Meetings worth scoring: not all-day, within `slack` of the interval.
    static func candidates(_ events: [CalendarEvent], start: Date, end: Date) -> [CalendarEvent] {
        let from = start.addingTimeInterval(-slack)
        let to = max(end, start).addingTimeInterval(slack)
        return events.filter { !$0.isAllDay && $0.startDate < to && $0.endDate > from }
    }

    static func timeScore(event: CalendarEvent, start: Date, end: Date) -> Double {
        let startProximity = max(0, 1 - abs(event.startDate.timeIntervalSince(start)) / startTolerance)
        let overlapShare: Double
        if end > start {
            let overlap = max(0, min(end, event.endDate).timeIntervalSince(max(start, event.startDate)))
            let shorter = min(end.timeIntervalSince(start), event.duration)
            overlapShare = shorter > 0 ? min(1, overlap / shorter) : 0
        } else {
            overlapShare = (event.startDate <= start && start < event.endDate) ? 1 : 0
        }
        return 0.6 * overlapShare + 0.4 * startProximity
    }

    static func overlapMinutes(event: CalendarEvent, start: Date, end: Date) -> Int {
        guard end > start else { return 0 }
        let overlap = max(0, min(end, event.endDate).timeIntervalSince(max(start, event.startDate)))
        return Int((overlap / 60).rounded())
    }

    /// Each given name or address against the attendees and the organizer, in any word order,
    /// Cyrillic or Latin.
    static func matchParticipants(_ participants: [String], attendees: [EventAttendee], organizer: String?) -> ParticipantMatch {
        var matched: [String] = []
        var unmatched: [String] = []
        for participant in participants {
            guard let matcher = EventPersonMatcher(query: participant) else { continue }
            let found = attendees.contains { matcher.matchesPerson(name: $0.name, email: $0.email) }
                || (!matcher.isEmailQuery && matcher.matchesPerson(name: organizer, email: nil))
            if found { matched.append(participant) } else { unmatched.append(participant) }
        }
        return ParticipantMatch(matched: matched, unmatched: unmatched)
    }

    /// Share of the hint's words (3+ letters) found at the start of the title's words.
    static func titleScore(hint: String, title: String) -> Double? {
        let hintWords = words(hint).filter { $0.count >= 3 }
        guard !hintWords.isEmpty else { return nil }
        let titleWords = words(title)
        let found = hintWords.filter { word in titleWords.contains { $0.hasPrefix(word) || word.hasPrefix($0) && $0.count >= 3 } }
        return Double(found.count) / Double(hintWords.count)
    }

    /// Weighted mean of the components that are known, lowered for meetings the user declined or
    /// that were cancelled: the recording may still be of them, but less likely.
    static func score(_ components: Components, event: CalendarEvent) -> Double {
        var parts: [(value: Double, weight: Double)] = [(components.time, 0.5)]
        if let participants = components.participants { parts.append((participants, 0.35)) }
        if let title = components.title { parts.append((title, 0.15)) }
        let weight = parts.reduce(0) { $0 + $1.weight }
        var total = parts.reduce(0) { $0 + $1.value * $1.weight } / weight
        if event.responseType == .declined { total *= 0.85 }
        if event.isEffectivelyCancelled { total *= 0.7 }
        return (total * 100).rounded() / 100
    }

    /// Two candidates this close are a coin toss: the caller should ask rather than pick.
    static let ambiguityMargin = 0.1

    static func confidence(scores: [Double]) -> (confidence: Confidence, ambiguous: Bool) {
        guard let best = scores.first else { return (.low, false) }
        let ambiguous = scores.count > 1 && best - scores[1] < ambiguityMargin
        if best >= 0.75, !ambiguous { return (.high, false) }
        if best >= 0.5 { return (.medium, ambiguous) }
        return (.low, ambiguous)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
