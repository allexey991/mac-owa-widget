import SwiftUI

/// The "Коллеги" section under the meeting list: who is free right now, and one click into the
/// room of whoever is.
///
/// Statuses are recomputed once a minute from the grid already on hand (`TimelineView`), not
/// fetched: a refresh is only about catching changes someone else made to their calendar.
struct ColleaguesSectionView: View {
    @EnvironmentObject private var presence: ColleaguePresenceService
    @EnvironmentObject private var service: CalendarService
    @EnvironmentObject private var localization: LocalizationService

    let horizontalPadding: CGFloat

    @State private var isExpanded = ColleaguesSectionExpansionStore.load()
    @State private var mode: Mode = .list
    @State private var showsAllRows = false
    @State private var searchQuery = ""
    @State private var searchResults: [ResolvedAttendee] = []
    @State private var isHeaderHovered = false
    @State private var isSearching = false
    @FocusState private var searchFieldFocused: Bool

    enum Mode: Equatable {
        case list
        case search
        case edit(WatchedColleague)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 0) {
                header(now: context.date)

                if isExpanded {
                    switch mode {
                    case .list:
                        listContent(now: context.date)
                    case .search:
                        searchContent
                    case .edit(let colleague):
                        ColleagueEditCardView(
                            colleague: colleague,
                            onSave: { updated in
                                presence.update(updated)
                                mode = .list
                            },
                            onCancel: { mode = .list },
                            onRemove: {
                                presence.remove(colleague)
                                mode = .list
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Header

    private func header(now: Date) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "person.2")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(localization.tr("colleagues.section.title"))
                .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 6)

            headerBadge(now: now)

            if presence.isRefreshing {
                ProgressView()
                    .scaleEffect(0.45)
                    .frame(width: 12, height: 12)
            }

            Button {
                showsAllRows = false
                isExpanded = true
                ColleaguesSectionExpansionStore.save(true)
                mode = .search
                searchFieldFocused = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(localization.tr("colleagues.add"))
            .accessibilityLabel(localization.tr("colleagues.add"))

            Button(action: toggleExpansion) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localization.tr(isExpanded ? "colleagues.collapse" : "colleagues.expand"))
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 7)
        // The whole header is the target, not just the chevron: it is the widest thing in the
        // section and the only reason to aim at a 10-point glyph was that it used to be the
        // only control. The plus and the chevron keep their own taps — the innermost gesture wins.
        .background(isHeaderHovered ? Color.secondary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleExpansion)
        .onHover { isHeaderHovered = $0 }
    }

    private func toggleExpansion() {
        isExpanded.toggle()
        ColleaguesSectionExpansionStore.save(isExpanded)
        if !isExpanded { mode = .list }
    }

    @ViewBuilder
    private func headerBadge(now: Date) -> some View {
        switch presence.freshness {
        case .stale(let since):
            Text(localization.tr("colleagues.offline.badge", localization.shortTime(since)))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .fresh where !presence.colleagues.isEmpty:
            let free = presence.freeCount(now: now)
            Text(localization.tr("colleagues.counter", free, presence.colleagues.count))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ColleaguePresenceStyle.color(for: .free))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(ColleaguePresenceStyle.color(for: .free).opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        default:
            EmptyView()
        }
    }

    // MARK: - List

    @ViewBuilder
    private func listContent(now: Date) -> some View {
        if presence.colleagues.isEmpty {
            emptyState
        } else {
            let ordered = presence.sortedColleagues(now: now)
            let limit = max(1, service.colleaguesRowLimit)
            let visible = showsAllRows ? ordered : Array(ordered.prefix(limit))

            VStack(spacing: 0) {
                ForEach(visible) { colleague in
                    ColleagueRowView(
                        colleague: colleague,
                        status: presence.status(for: colleague, now: now),
                        isStale: isStale,
                        now: now,
                        onJoin: join,
                        onEdit: { mode = .edit(colleague) },
                        onRemove: { presence.remove(colleague) }
                    )
                }

                if ordered.count > limit {
                    Button {
                        showsAllRows.toggle()
                    } label: {
                        Text(showsAllRows
                            ? localization.tr("colleagues.showLess")
                            : localization.tr("colleagues.more", ordered.count - limit))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, horizontalPadding + 22)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, 2)
        }
    }

    private var isStale: Bool {
        if case .stale = presence.freshness { return true }
        return false
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(localization.tr("colleagues.empty.title"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                mode = .search
                searchFieldFocused = true
            } label: {
                Text(localization.tr("colleagues.empty.action"))
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, horizontalPadding + 12)
        .padding(.bottom, 12)
    }

    // MARK: - Search

    private var searchContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField(localization.tr("colleagues.search.placeholder"), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFieldFocused)

                if isSearching {
                    ProgressView().scaleEffect(0.4).frame(width: 12, height: 12)
                }

                Button {
                    searchQuery = ""
                    searchResults = []
                    mode = .list
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localization.tr("colleagues.edit.cancel"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 6)

            if !searchResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(searchResults) { attendee in
                        searchResultRow(attendee)
                    }
                }
                .padding(.bottom, 4)
            } else if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty, !isSearching {
                Text(localization.tr("colleagues.search.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: searchQuery) { await runSearch() }
    }

    private func searchResultRow(_ attendee: ResolvedAttendee) -> some View {
        let alreadyAdded = presence.contains(attendee)
        return Button {
            guard !alreadyAdded else { return }
            presence.add(attendee)
            searchQuery = ""
            searchResults = []
            if let stored = presence.colleagues.first(where: { $0.id == attendee.email.lowercased() }) {
                mode = .edit(stored)
            } else {
                mode = .list
            }
        } label: {
            HStack(spacing: 8) {
                InitialsAvatar(name: attendee.displayName, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attendee.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(attendee.jobTitle ?? attendee.email)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if alreadyAdded {
                    Text(localization.tr("colleagues.search.already"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
    }

    private func runSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        // Typing is faster than FindPeople: wait out the burst before spending a request.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        isSearching = true
        defer { isSearching = false }
        do {
            let people = try await presence.searchPeople(query: query)
            guard !Task.isCancelled else { return }
            searchResults = Array(people.prefix(6))
        } catch {
            guard !Task.isCancelled else { return }
            searchResults = []
        }
    }

    private func join(_ url: URL) {
        _ = MeetingURLOpener.open(url)
        PostJoinDismissController.shared.dismissAfterJoin(context: .popoverContent)
    }
}
