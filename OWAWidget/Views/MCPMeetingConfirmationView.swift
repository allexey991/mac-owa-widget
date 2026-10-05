import SwiftUI

/// What an MCP client wants to create, with "Create" and "Cancel". Shown by
/// `MCPMeetingConfirmationController`; nothing is sent to Exchange before "Create".
struct MCPMeetingConfirmationView: View {
    static let visibleAttendeeLimit = 8

    let proposal: MCPMeetingProposal
    let deadline: Date
    let localization: LocalizationService
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                header
                meeting
                attendees
                if !proposal.conflicts.isEmpty { conflicts }
                if !agendaPreview.isEmpty {
                    Text(agendaPreview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)

            Divider().opacity(0.7)

            HStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(localization.tr("mcp.confirm.countdown", max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(localization.tr("mcp.confirm.reject"), action: onReject)
                    .keyboardShortcut(.cancelAction)
                // No default-action shortcut: a stray Return must not send invitations.
                Button(localization.tr("mcp.confirm.create"), action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 400, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
            Text(proposal.client.isEmpty
                ? localization.tr("mcp.confirm.titleUnknownClient")
                : localization.tr("mcp.confirm.title", proposal.client))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var meeting: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(proposal.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(timeText)
                .font(.system(size: 12))
            if !proposal.location.isEmpty {
                Label(proposal.location, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var attendees: some View {
        if proposal.required.isEmpty && proposal.optional.isEmpty {
            Text(localization.tr("mcp.confirm.noAttendees"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                attendeeSection(localization.tr("mcp.confirm.required"), proposal.required)
                attendeeSection(localization.tr("mcp.confirm.optional"), proposal.optional)
                if proposal.hasExternalAttendees {
                    Label(localization.tr("mcp.confirm.externalWarning"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(localization.tr("mcp.confirm.invitationsNote"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func attendeeSection(_ title: String, _ people: [MCPMeetingProposal.Attendee]) -> some View {
        if !people.isEmpty {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(people.prefix(Self.visibleAttendeeLimit), id: \.email) { person in
                HStack(spacing: 6) {
                    if let name = person.name, !name.isEmpty {
                        Text(name).font(.system(size: 12)).lineLimit(1)
                    }
                    Text(person.email)
                        .font(.system(size: 11))
                        .foregroundStyle(person.isExternal ? .orange : .secondary)
                        .lineLimit(1)
                    if person.isExternal {
                        Text(localization.tr("mcp.confirm.external"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    }
                }
            }
            if people.count > Self.visibleAttendeeLimit {
                Text(localization.tr("mcp.confirm.more", people.count - Self.visibleAttendeeLimit))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var conflicts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(localization.tr("mcp.confirm.conflicts"), systemImage: "exclamationmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
            ForEach(Array(proposal.conflicts.prefix(3).enumerated()), id: \.offset) { _, conflict in
                Text("\(Self.hoursText(conflict.start, conflict.end, locale: localization.locale))  \(conflict.title)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var timeText: String {
        let day = DateFormatter()
        day.locale = localization.locale
        day.timeZone = AppTimeZone.zone
        day.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        let minutes = Int(proposal.end.timeIntervalSince(proposal.start) / 60)
        return "\(day.string(from: proposal.start)), \(Self.hoursText(proposal.start, proposal.end, locale: localization.locale)) · \(localization.minutes(minutes))"
    }

    private var agendaPreview: String {
        proposal.agenda.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hoursText(_ start: Date, _ end: Date, locale: Locale) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = AppTimeZone.zone
        time.setLocalizedDateFormatFromTemplate("Hmm")
        return "\(time.string(from: start))–\(time.string(from: end))"
    }
}

extension MCPMeetingProposal {
    var hasExternalAttendees: Bool {
        (required + optional).contains(where: \.isExternal)
    }
}
