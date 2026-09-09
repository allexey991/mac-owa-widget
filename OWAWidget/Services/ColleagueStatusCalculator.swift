import Foundation

/// Turns an Exchange merged free/busy string into "what is this person doing right now, and until
/// when". Pure: no clock, no network, no formatting.
///
/// The string is one character per interval (30 minutes) counted from `windowStart`, so the
/// current cell is an index and the end of the state is a run length. That also means the current
/// status keeps moving on its own between fetches — the grid already covers the whole window.
enum ColleagueStatusCalculator {
    static func status(from availability: AttendeeAvailability, now: Date) -> ColleagueStatus {
        let chars = Array(availability.mergedFreeBusy)
        guard !chars.isEmpty, availability.intervalMinutes > 0 else { return .unknown }

        let interval = TimeInterval(availability.intervalMinutes) * 60
        let offset = now.timeIntervalSince(availability.windowStart)
        guard offset >= 0 else { return .unknown }

        let index = Int(offset / interval)
        guard index < chars.count else { return .unknown }

        let presence = ColleaguePresence(freeBusyCode: chars[index])

        // Walk forward while the cell means the same thing. Different codes can map to the same
        // presence only for `noData`, and there the end time is meaningless anyway.
        var end = index + 1
        while end < chars.count, ColleaguePresence(freeBusyCode: chars[end]) == presence {
            end += 1
        }

        // The run reaches the end of what was downloaded: we do not know when it ends.
        guard end < chars.count else { return ColleagueStatus(presence: presence, until: nil) }

        let until = availability.windowStart.addingTimeInterval(TimeInterval(end) * interval)
        return ColleagueStatus(presence: presence, until: until)
    }

    /// Statuses keyed by lowercased mailbox address, matching ``WatchedColleague/id``.
    static func statuses(from availabilities: [AttendeeAvailability], now: Date) -> [String: ColleagueStatus] {
        var result: [String: ColleagueStatus] = [:]
        for availability in availabilities {
            result[availability.email.lowercased()] = status(from: availability, now: now)
        }
        return result
    }
}
