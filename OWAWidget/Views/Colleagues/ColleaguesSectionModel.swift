import Foundation

/// Interface state of the colleagues section, owned by the popover.
///
/// It lives outside the two views because the section is split in half: the header stays in the
/// popover's vertical flow while the list floats over the timeline, and both have to agree on
/// whether the section is open and what it is showing.
@MainActor
final class ColleaguesSectionModel: ObservableObject {
    enum Mode: Equatable {
        case list
        case search
        case edit(WatchedColleague)
    }

    @Published var isExpanded: Bool {
        didSet {
            guard isExpanded != oldValue else { return }
            ColleaguesSectionExpansionStore.save(isExpanded, to: defaults)
            if !isExpanded { mode = .list }
        }
    }

    @Published var mode: Mode = .list

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isExpanded = ColleaguesSectionExpansionStore.load(from: defaults)
    }

    func toggleExpansion() {
        isExpanded.toggle()
    }

    func openSearch() {
        isExpanded = true
        mode = .search
    }

    func edit(_ colleague: WatchedColleague) {
        isExpanded = true
        mode = .edit(colleague)
    }

    func backToList() {
        mode = .list
    }

    /// Escape unwinds one layer: a card or the search box first, the whole section after.
    /// Returns `false` when there was nothing of ours to close.
    func handleEscape() -> Bool {
        guard isExpanded else { return false }
        if mode != .list {
            mode = .list
        } else {
            isExpanded = false
        }
        return true
    }
}
