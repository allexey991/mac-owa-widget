import Foundation

/// Shortens an address-book name to fit the colleague row.
///
/// Exchange hands out full official names ("Юшина Оксана Владимировна"), which eat most of a
/// 420-point row and end in an ellipsis. The row shows "Юшина О.В." instead: the surname is what
/// the user scans for, and the initials are what tell two Ивановых apart.
enum ColleagueNameFormatter {
    static func abbreviated(_ fullName: String) -> String {
        let parts = fullName
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard let surname = parts.first else { return fullName }
        guard parts.count > 1 else { return surname }

        let initials = parts.dropFirst().prefix(2).compactMap { part -> String? in
            // Already abbreviated upstream ("О.В."): keep it rather than clipping it to "О.".
            if part.contains(".") { return part }
            guard let first = part.first, first.isLetter else { return nil }
            return "\(first)."
        }

        guard !initials.isEmpty else { return surname }
        return "\(surname) \(initials.joined())"
    }
}
