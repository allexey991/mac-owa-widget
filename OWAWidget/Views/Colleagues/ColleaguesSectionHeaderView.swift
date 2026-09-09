import SwiftUI

/// The always-visible half of the colleagues section: one 32-point row above the footer.
///
/// Closed, it still answers the question the section exists for — the avatars are the people who
/// are free right now, and clicking one goes straight into their room.
struct ColleaguesSectionHeaderView: View {
    @ObservedObject var model: ColleaguesSectionModel
    let horizontalPadding: CGFloat
    let onJoin: (URL) -> Void

    @EnvironmentObject private var presence: ColleaguePresenceService
    @EnvironmentObject private var localization: LocalizationService

    @State private var isHovered = false

    /// Avatars shown before the row starts collapsing into "+N".
    private let maxAvatars = 4

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 7) {
                Image(systemName: "person.2")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(localization.tr("colleagues.section.title"))
                    .font(.system(size: 12, weight: .semibold))

                Spacer(minLength: 6)

                trailingSummary(now: context.date)

                if presence.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 12, height: 12)
                }

                Button {
                    model.openSearch()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(localization.tr("colleagues.add"))
                .accessibilityLabel(localization.tr("colleagues.add"))

                Button(action: model.toggleExpansion) {
                    Image(systemName: model.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localization.tr(model.isExpanded ? "colleagues.collapse" : "colleagues.expand"))
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 7)
            // The whole header is the target, not just the chevron. The plus, the chevron and the
            // avatars keep their own taps — the innermost gesture wins.
            .background(isHovered ? Color.secondary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { model.toggleExpansion() }
            .onHover { isHovered = $0 }
        }
    }

    /// Expanded, the header only has to count. Closed, it carries the free colleagues themselves.
    @ViewBuilder
    private func trailingSummary(now: Date) -> some View {
        switch presence.freshness {
        case .stale(let since):
            badge(
                text: localization.tr("colleagues.offline.badge", localization.shortTime(since)),
                color: .secondary,
                background: Color.secondary.opacity(0.12)
            )
        case .fresh where !presence.colleagues.isEmpty:
            if model.isExpanded {
                counterBadge(now: now)
            } else {
                freeAvatars(now: now)
            }
        default:
            EmptyView()
        }
    }

    private func counterBadge(now: Date) -> some View {
        badge(
            text: localization.tr("colleagues.counter", presence.freeCount(now: now), presence.colleagues.count),
            color: ColleaguePresenceStyle.color(for: .free),
            background: ColleaguePresenceStyle.color(for: .free).opacity(0.18)
        )
    }

    @ViewBuilder
    private func freeAvatars(now: Date) -> some View {
        let free = presence.freeColleagues(now: now)

        if free.isEmpty {
            counterBadge(now: now)
        } else {
            HStack(spacing: 4) {
                ForEach(free.prefix(maxAvatars)) { colleague in
                    Button {
                        if let url = ColleagueRoomLink.normalized(colleague.roomURL) {
                            onJoin(url)
                        } else {
                            model.isExpanded = true
                        }
                    } label: {
                        InitialsAvatar(name: colleague.displayName, size: 18)
                            .overlay(
                                Circle().strokeBorder(ColleaguePresenceStyle.color(for: .free), lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(freeHelp(for: colleague, now: now))
                    .accessibilityLabel(freeHelp(for: colleague, now: now))
                }

                if free.count > maxAvatars {
                    Text("+\(free.count - maxAvatars)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func freeHelp(for colleague: WatchedColleague, now: Date) -> String {
        let status = ColleagueStatusFormatter.text(
            for: presence.status(for: colleague, now: now),
            now: now,
            localization: localization
        )
        return "\(colleague.displayName) · \(status)"
    }

    private func badge(text: String, color: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
