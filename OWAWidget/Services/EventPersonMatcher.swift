import Foundation

/// Decides whether a person someone asked about ("Иванов", "ivan.ivanov@corp.ru") took part in a
/// meeting. Pure, for the MCP `find_events_with_person` tool.
///
/// Each word of a name query must start a *different* word of the person's name (or of the local
/// part of their address): "Иван Иванов" finds "Иванов Иван Петрович" but not "Иванов Пётр", which
/// plain substring search would accept because "иван" is inside "иванов". Case, word order and
/// script do not matter (`OWAPersonSearchTokenMatch.normalizedForms` adds a Latin
/// transliteration, so "иванов" finds "Ivanov"). An address must match exactly, ignoring case.
struct EventPersonMatcher: Sendable {
    enum Role: String, Sendable {
        case organizer, required, optional, title
    }

    struct Match: Equatable, Sendable {
        let role: Role
        let name: String?
        let email: String?
    }

    let email: String?
    let tokens: [String]

    /// `nil` for an empty query.
    init?(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("@"), !trimmed.contains(" ") {
            email = trimmed.lowercased()
            tokens = []
        } else {
            email = nil
            tokens = trimmed
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            if tokens.isEmpty { return nil }
        }
    }

    var isEmailQuery: Bool { email != nil }

    func matchesPerson(name: String?, email personEmail: String?) -> Bool {
        if let email {
            return personEmail?.lowercased() == email
        }
        var words = Self.words(name ?? "")
        if let local = personEmail?.split(separator: "@").first {
            words += Self.words(String(local))
        }
        return Self.tokensMatchDistinctWords(tokens, words)
    }

    /// Organizer by display name. Sync knows only the organizer's name, so an address query can
    /// match it only through names already learned for that address (`knownNames`).
    func matchesOrganizer(_ organizer: String?, knownNames: Set<String>) -> Bool {
        guard let organizer, !organizer.isEmpty else { return false }
        if isEmailQuery {
            return knownNames.contains(Self.normalizedName(organizer))
        }
        return matchesPerson(name: organizer, email: nil)
    }

    /// A weak signal: the name appears in the title ("1:1 Иванов / Петров"). Titles usually carry
    /// only the surname, so a multi-word query matches on its longest word.
    func matchesTitle(_ title: String) -> Bool {
        guard !isEmailQuery, !title.isEmpty else { return false }
        if tokens.allSatisfy({ titleContains(title, $0) }) { return true }
        guard tokens.count > 1, let longest = tokens.max(by: { $0.count < $1.count }), longest.count >= 4 else {
            return false
        }
        return titleContains(title, longest)
    }

    func match(attendee: EventAttendee) -> Match? {
        guard matchesPerson(name: attendee.name, email: attendee.email) else { return nil }
        let role: Role = attendee.kind == .optional ? .optional : .required
        return Match(role: role, name: attendee.name, email: attendee.email)
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func titleContains(_ title: String, _ token: String) -> Bool {
        Self.tokensMatchDistinctWords([token], Self.words(title))
    }

    /// Normalised forms of each word (lowercased, plus a Latin transliteration).
    private static func words(_ text: String) -> [Set<String>] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map(OWAPersonSearchTokenMatch.normalizedForms)
    }

    /// Longest tokens claim words first, so "Иван Иванов" pairs "иванов" with "Иванов" before
    /// "иван" gets a chance to take it.
    private static func tokensMatchDistinctWords(_ tokens: [String], _ words: [Set<String>]) -> Bool {
        var used = Set<Int>()
        for token in tokens.sorted(by: { $0.count > $1.count }) {
            let forms = OWAPersonSearchTokenMatch.normalizedForms(token)
            guard let index = words.indices.first(where: { index in
                !used.contains(index) && words[index].contains { word in forms.contains { word.hasPrefix($0) } }
            }) else { return false }
            used.insert(index)
        }
        return true
    }
}
