import CryptoKit
import Foundation

/// Localized fragments the feed embeds in event text. Passed in so the builder stays a pure
/// function of its arguments.
struct ICSFeedStrings: Sendable, Equatable {
    let cancelledPrefix: String
    let declinedPrefix: String
    let organizerLabel: String
    let attendeesLabel: String
}

/// Renders events as the iCalendar (RFC 5545) text that Calendar.app subscribes to.
///
/// Calendar replaces the whole subscribed calendar on every refresh and matches events by `UID`,
/// so every occurrence needs its own stable UID. `icalUID` cannot be used: it is shared by all
/// occurrences of a series, and Calendar would merge them into one event.
enum ICSFeedBuilder {
    static let calendarName = "OWA Widget"

    static func build(
        events: [CalendarEvent],
        generatedAt: Date,
        timeZone: TimeZone,
        strings: ICSFeedStrings
    ) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//OWA Widget//ICS Feed//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "X-WR-CALNAME:\(escapeText(calendarName))",
            "REFRESH-INTERVAL;VALUE=DURATION:PT5M",
            "X-PUBLISHED-TTL:PT5M",
        ]
        let stamp = utcTimestamp(generatedAt)
        for event in events {
            lines += eventLines(event, stamp: stamp, timeZone: timeZone, strings: strings)
        }
        lines.append("END:VCALENDAR")
        return lines.map { fold($0) + "\r\n" }.joined()
    }

    /// Stable per occurrence, and opaque: Exchange ItemIds are internal identifiers that have no
    /// business leaving the app.
    static func uid(for event: CalendarEvent) -> String {
        let digest = SHA256.hash(data: Data((event.accountID.uuidString + "|" + event.id).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32)) + "@owawidget"
    }

    /// TEXT value escaping (RFC 5545 §3.3.11). Line breaks of any flavour become `\n`.
    static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Folds a content line to at most 75 octets per physical line (RFC 5545 §3.1). Breaks only
    /// between Unicode scalars, so a multi-byte UTF-8 sequence is never split.
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var result = ""
        var current = ""
        var currentBytes = 0
        var limit = 75
        for scalar in line.unicodeScalars {
            let size = String(scalar).utf8.count
            if currentBytes + size > limit {
                result += current + "\r\n "
                current = ""
                currentBytes = 0
                limit = 74 // the leading space of a continuation line counts toward 75
            }
            current.unicodeScalars.append(scalar)
            currentBytes += size
        }
        return result + current
    }

    // MARK: - Private

    private static func eventLines(
        _ event: CalendarEvent,
        stamp: String,
        timeZone: TimeZone,
        strings: ICSFeedStrings
    ) -> [String] {
        let isDeclined = event.responseType == .declined
        var summary = event.title
        if event.isCancelled {
            summary = strings.cancelledPrefix + summary
        } else if isDeclined {
            summary = strings.declinedPrefix + summary
        }

        let status: String
        if event.isCancelled {
            status = "CANCELLED"
        } else if event.responseType == .tentative {
            status = "TENTATIVE"
        } else {
            status = "CONFIRMED"
        }

        var lines = [
            "BEGIN:VEVENT",
            "UID:\(uid(for: event))",
            "DTSTAMP:\(stamp)",
        ]
        if event.isAllDay {
            lines.append("DTSTART;VALUE=DATE:\(localDate(event.startDate, timeZone: timeZone))")
            lines.append("DTEND;VALUE=DATE:\(localDate(event.endDate, timeZone: timeZone))")
        } else {
            lines.append("DTSTART:\(utcTimestamp(event.startDate))")
            lines.append("DTEND:\(utcTimestamp(event.endDate))")
        }
        lines.append("SUMMARY:\(escapeText(summary))")
        lines.append("STATUS:\(status)")
        lines.append("TRANSP:\(event.isCancelled || isDeclined ? "TRANSPARENT" : "OPAQUE")")

        if let location = nonEmpty(event.location) {
            lines.append("LOCATION:\(escapeText(location))")
        }
        if let joinURL = event.joinURL {
            lines.append("URL:\(joinURL.absoluteString)")
        }
        if let description = description(for: event, strings: strings) {
            lines.append("DESCRIPTION:\(escapeText(description))")
        }
        let categories = event.categories.compactMap(nonEmpty)
        if !categories.isEmpty {
            lines.append("CATEGORIES:\(categories.map(escapeText).joined(separator: ","))")
        }
        if !event.isCancelled && !isDeclined {
            let uid = uid(for: event)
            for minutes in alarmMinutes(for: event) {
                lines += alarmLines(minutesBeforeStart: minutes, eventUID: uid, summary: summary)
            }
        }
        lines.append("END:VEVENT")
        return lines
    }

    /// Many meetings are created without a reminder, and Calendar.app only notifies through
    /// `VALARM`. The default — a minute before and at the start — is what the user asked for.
    static let defaultAlarmMinutes = [1, 0]

    /// The server's reminder when it has one; otherwise the default. An all-day event without
    /// one gets none: an alert at midnight helps nobody.
    static func alarmMinutes(for event: CalendarEvent) -> [Int] {
        if let minutes = event.reminderMinutesBeforeStart, minutes >= 0 { return [minutes] }
        return event.isAllDay ? [] : defaultAlarmMinutes
    }

    /// `X-WR-ALARMUID` keeps the alarm's identity across refreshes, so Calendar does not treat an
    /// already dismissed alert as new.
    private static func alarmLines(minutesBeforeStart minutes: Int, eventUID: String, summary: String) -> [String] {
        let alarmUID = "\(eventUID.prefix(32))-alarm-\(minutes)@owawidget"
        return [
            "BEGIN:VALARM",
            "UID:\(alarmUID)",
            "X-WR-ALARMUID:\(alarmUID)",
            "ACTION:DISPLAY",
            "DESCRIPTION:\(escapeText(summary))",
            "TRIGGER:\(minutes == 0 ? "PT0S" : "-PT\(minutes)M")",
            "END:VALARM",
        ]
    }

    /// Join link first: where Calendar.app looks for a "Join" button is undocumented, so the link
    /// is also kept in LOCATION (as Exchange has it) and URL.
    private static func description(for event: CalendarEvent, strings: ICSFeedStrings) -> String? {
        var details: [String] = []
        if let preview = nonEmpty(event.bodyPreview) { details.append(preview) }
        if let organizer = nonEmpty(event.organizer) {
            details.append("\(strings.organizerLabel): \(organizer)")
        }
        let attendees = event.attendees.compactMap(nonEmpty)
        if !attendees.isEmpty {
            details.append("\(strings.attendeesLabel): \(attendees.joined(separator: ", "))")
        }

        let blocks = [event.joinURL?.absoluteString, details.isEmpty ? nil : details.joined(separator: "\n")]
            .compactMap { $0 }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func utcTimestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    private static func localDate(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
    }
}
