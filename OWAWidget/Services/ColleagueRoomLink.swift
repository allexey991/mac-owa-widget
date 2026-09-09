import Foundation

/// Validation and platform detection for the personal room link the user types in by hand.
///
/// The link is user input that later becomes an `NSWorkspace.open`, so it goes through the same
/// scheme check as meeting links instead of a bare `URL(string:)`.
enum ColleagueRoomLink {
    static func normalized(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // The shared opener turns anything without a scheme into https, which is right for links
        // lifted out of an invite but too generous for a field the user types into: a sentence
        // would silently become a URL. A room link has to look like one — no spaces, real host.
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        guard let url = MeetingURLOpener.safeURL(fromString: trimmed),
              let host = url.host, host.contains(".")
        else { return nil }
        return url
    }

    static func isValid(_ raw: String?) -> Bool {
        normalized(raw) != nil
    }

    /// Empty input is valid: a colleague without a room is a normal row, just without a button.
    static func isAcceptableInput(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || normalized(trimmed) != nil
    }

    static func platform(for raw: String?) -> MeetingPlatform {
        guard let url = normalized(raw) else { return .generic }
        return MeetingURLDetector().detectPlatform(from: url.absoluteString)
    }
}
