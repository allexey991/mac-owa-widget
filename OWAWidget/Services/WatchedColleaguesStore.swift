import Foundation

/// The colleagues whose availability the popover watches.
///
/// Names, addresses, job titles and room links come from the corporate address book and from the
/// user, so the list is encrypted at rest like every other store here rather than sitting in
/// `UserDefaults`. There is no legacy plist key: the feature ships straight into `SecureStore`.
enum WatchedColleaguesStore {
    typealias Store = SecureCodableStore<[WatchedColleague]>

    static let storageName = "watchedColleagues"
    /// Every colleague costs characters in one availability response, not a request of their own,
    /// so the cap is about a readable list rather than about load.
    static let maxCount = 30

    static let shared: Store = makeStore()

    static func makeStore(
        secureStore: SecureStore = .shared,
        defaults: UserDefaults = .standard
    ) -> Store {
        Store(
            name: storageName,
            legacyKey: nil,
            store: secureStore,
            defaults: defaults,
            policy: .fallBackToLegacy
        )
    }

    static func load(store: Store = shared) -> [WatchedColleague] {
        store.load() ?? []
    }

    static func save(_ colleagues: [WatchedColleague], store: Store = shared) {
        store.save(Array(colleagues.prefix(maxCount)))
    }

    /// Adds a colleague, or refreshes the address-book fields of one already on the list without
    /// dropping the room link the user typed in.
    static func add(_ colleague: WatchedColleague, store: Store = shared) -> [WatchedColleague] {
        var current = load(store: store)
        if let index = current.firstIndex(where: { $0.id == colleague.id }) {
            current[index].displayName = colleague.displayName
            current[index].jobTitle = colleague.jobTitle
            if let room = colleague.roomURL, !room.isEmpty {
                current[index].roomURL = room
            }
        } else {
            current.append(colleague)
        }
        save(current, store: store)
        return load(store: store)
    }

    static func update(_ colleague: WatchedColleague, store: Store = shared) -> [WatchedColleague] {
        var current = load(store: store)
        guard let index = current.firstIndex(where: { $0.id == colleague.id }) else {
            return add(colleague, store: store)
        }
        current[index] = colleague
        save(current, store: store)
        return load(store: store)
    }

    static func remove(id: String, store: Store = shared) -> [WatchedColleague] {
        let current = load(store: store).filter { $0.id != id.lowercased() }
        save(current, store: store)
        return load(store: store)
    }

    /// Moves one colleague into the slot another row occupies right now, which is what a drag
    /// onto that row means. Removing first and inserting at the same index lands the dragged
    /// person exactly where the target sat, in both directions — no off-by-one correction.
    static func move(id: String, toIndex index: Int, store: Store = shared) -> [WatchedColleague] {
        var current = load(store: store)
        guard let from = current.firstIndex(where: { $0.id == id.lowercased() }) else { return current }
        let moved = current.remove(at: from)
        current.insert(moved, at: max(0, min(index, current.count)))
        save(current, store: store)
        return load(store: store)
    }

    /// Moves one colleague one place up or down. The stored order is what the section shows, so
    /// this is the whole of "reordering" — there is no separate index to keep in step.
    static func move(id: String, offset: Int, store: Store = shared) -> [WatchedColleague] {
        var current = load(store: store)
        guard let index = current.firstIndex(where: { $0.id == id.lowercased() }) else { return current }
        let target = index + offset
        guard current.indices.contains(target) else { return current }
        current.swapAt(index, target)
        save(current, store: store)
        return load(store: store)
    }
}
