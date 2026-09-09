import SwiftUI

/// Colours and glyphs for colleague presence.
///
/// The hues are the ones the create-meeting availability grid already uses for the same four
/// Exchange states, so a colleague marked busy in the section matches the busy cell in the grid.
/// `noData` is the one addition: a state the grid never had to name.
enum ColleaguePresenceStyle {
    static func color(for presence: ColleaguePresence) -> Color {
        switch presence {
        case .free: Color(hue: 0.385, saturation: 0.42, brightness: 0.78)
        case .tentative: Color(hue: 0.075, saturation: 0.48, brightness: 0.90)
        case .busy: Color(hue: 0.975, saturation: 0.42, brightness: 0.80)
        case .away: Color(hue: 0.700, saturation: 0.35, brightness: 0.80)
        case .noData: Color.secondary.opacity(0.55)
        }
    }

    /// Whether the join button keeps the accent colour. Calling someone into their room while they
    /// are in another meeting is possible but rarely the intent, so the button steps back.
    static func joinIsProminent(for presence: ColleaguePresence) -> Bool {
        switch presence {
        case .free, .tentative: true
        case .busy, .away, .noData: false
        }
    }
}

/// The section's collapsed/expanded state. Interface state, so `UserDefaults` rather than the
/// encrypted store — it says nothing about who the user watches.
enum ColleaguesSectionExpansionStore {
    private static let key = "colleaguesSectionExpanded"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    static func save(_ expanded: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(expanded, forKey: key)
    }
}
