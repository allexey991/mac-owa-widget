import SwiftUI
import AppKit

struct MeetingDaySection: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let date: Date
    let timedEvents: [CalendarEvent]
    let allDayEvents: [CalendarEvent]

    static func partition(
        events: [CalendarEvent],
        label: String,
        dayStart: Date,
        dayEnd: Date
    ) -> MeetingDaySection {
        let inDay = events.filter { $0.startDate < dayEnd && $0.endDate > dayStart }
        let allDay = inDay
            .filter { $0.isAllDay }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let timed = inDay.filter { !$0.isAllDay }
        return MeetingDaySection(
            label: label,
            date: dayStart,
            timedEvents: timed,
            allDayEvents: allDay
        )
    }
}

struct MeetingListView: View {
    let sections: [MeetingDaySection]
    var contentHorizontalPadding: CGFloat = 12
    var selectedEventID: String? = nil
    var onSelect: (CalendarEvent) -> Void = { _ in }
    @EnvironmentObject private var localization: LocalizationService
    @State private var hasAutoScrolledToCurrentSlot = false

    private let timeColumnWidth: CGFloat = 56
    private let timelinePointsPerMinute: CGFloat = 1.0
    private let cardGap: CGFloat = 0
    private let slotDurationMinutes = 30

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            hourlySection(section: section)
                        } header: {
                            VStack(alignment: .leading, spacing: 0) {
                                sectionHeader(section.label)
                                AllDayEventsHeaderView(
                                    events: section.allDayEvents,
                                    contentHorizontalPadding: contentHorizontalPadding,
                                    timeColumnWidth: timeColumnWidth,
                                    selectedEventID: selectedEventID,
                                    onSelect: onSelect
                                )
                            }
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .onAppear {
                hasAutoScrolledToCurrentSlot = false
                scrollToCurrentSlotIfNeeded(proxy: proxy)
            }
            .onChange(of: sections.map(\.timedEvents.count)) { _ in
                scrollToCurrentSlotIfNeeded(proxy: proxy)
            }
            .onChange(of: sections.first?.date) { _ in
                hasAutoScrolledToCurrentSlot = false
                scrollToCurrentSlotIfNeeded(proxy: proxy)
            }
        }
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, contentHorizontalPadding)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }

    // MARK: - Section layout

    @ViewBuilder
    private func hourlySection(
        section: MeetingDaySection
    ) -> some View {
        let slots = TimelineMeetingLayout.makeHourSlots(
            events: section.timedEvents,
            sectionDate: section.date,
            calendar: AppTimeZone.calendar,
            referenceDate: Date()
        )

        if let firstSlot = slots.first {
            let allItems: [HourSlotMeetingItem] = {
                var seenIDs = Set<String>()
                return slots.flatMap(\.items).filter { seenIDs.insert($0.id).inserted }
            }()
            let gridStart = firstSlot.startDate
            let fixedSlotHeight = CGFloat(slotDurationMinutes) * timelinePointsPerMinute
            let gridPixelHeight = CGFloat(slots.count) * fixedSlotHeight

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(slots) { slot in
                        timeGridRow(slot, fixedHeight: fixedSlotHeight)
                            .id(slotID(for: section.date, slotStart: slot.startDate))
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        if !allItems.isEmpty {
                            let leftInset = timeColumnWidth + 10
                            let cardAreaWidth = max(0, geo.size.width - leftInset)
                            let laneSpacing: CGFloat = 0

                            ForEach(allItems) { item in
                                let laneCount = max(1, item.laneCount)
                                let cardFrame = TimelineMeetingLayout.cardFrame(
                                    for: item.event,
                                    laneIndex: item.laneIndex,
                                    laneCount: laneCount,
                                    gridStart: gridStart,
                                    leftInset: Double(leftInset),
                                    cardAreaWidth: Double(cardAreaWidth),
                                    laneSpacing: Double(laneSpacing),
                                    pointsPerMinute: Double(timelinePointsPerMinute),
                                    verticalGap: Double(cardGap)
                                )

                                Button { onSelect(item.event) } label: {
                                    TimelineMeetingBlockView(
                                        event: item.event,
                                        compact: laneCount > 1,
                                        showsOrganizer: TimelineMeetingLayout.showsTimelineOrganizer(
                                            laneIndex: item.laneIndex,
                                            laneCount: laneCount,
                                            eventDuration: item.event.duration
                                        ),
                                        isSelected: selectedEventID == item.event.id
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(a11yEventLabel(item.event))
                                .accessibilityHint(localization.tr("a11y.meeting.open.details.hint"))
                                .frame(
                                    width: CGFloat(cardFrame.width),
                                    height: CGFloat(cardFrame.height),
                                    alignment: .topLeading
                                )
                                .position(
                                    x: CGFloat(cardFrame.centerX),
                                    y: CGFloat(cardFrame.centerY)
                                )
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: max(geo.size.height, gridPixelHeight), alignment: .topLeading)
                }
            }
            .padding(.horizontal, contentHorizontalPadding)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Time grid row (no cards)

    private func timeGridRow(_ slot: DayHourSlot, fixedHeight: CGFloat) -> some View {
        let isCurrentSlot = isCurrentTimeSlot(slot)
        let isHalfHourSlot = AppTimeZone.calendar.component(.minute, from: slot.startDate) == 30

        return HStack(alignment: .top, spacing: 10) {
            Text(!isHalfHourSlot ? localization.shortTime(slot.startDate) : "")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: timeColumnWidth, alignment: .trailing)

            Color.clear
        }
        .frame(height: fixedHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrentSlot ? Color.accentColor.opacity(0.08) : .clear)
        )
        .overlay(alignment: .top) {
            if !isHalfHourSlot {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.4))
                    .frame(height: 1)
                    .padding(.leading, timeColumnWidth + 10)
            }
        }
        // The grid is a visual scaffold; VoiceOver should focus on actual meeting cards.
        .accessibilityHidden(true)
    }

    private func a11yEventLabel(_ event: CalendarEvent) -> String {
        let time = "\(localization.shortTime(event.startDate))–\(localization.shortTime(event.endDate))"
        var parts: [String] = [event.title, time]
        if event.isHappeningNow {
            parts.append(localization.tr("meeting.happening.now"))
        }
        if let organizer = event.organizer, !organizer.isEmpty {
            parts.append(organizer)
        }
        if event.joinURLForActions != nil {
            parts.append(localization.tr("a11y.meeting.has.join"))
        }
        if event.isEffectivelyCancelled {
            parts.append(localization.tr("meeting.status.cancelled"))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Scroll helpers

    private func isCurrentTimeSlot(_ slot: DayHourSlot) -> Bool {
        let now = Date()
        return slot.startDate <= now && now < slot.endDate
    }

    private func slotID(for sectionDate: Date, slotStart: Date) -> String {
        let sectionKey = Int(sectionDate.timeIntervalSince1970)
        let slotKey = Int(slotStart.timeIntervalSince1970)
        return "slot-\(sectionKey)-\(slotKey)"
    }


    private func scrollToCurrentSlotIfNeeded(proxy: ScrollViewProxy) {
        guard !hasAutoScrolledToCurrentSlot else { return }
        guard let id = scrollAnchorSlotID() else { return }

        hasAutoScrolledToCurrentSlot = true
        // Deliberately not animated. This runs as the list appears, so there is no previous
        // position for the user to have seen it travel from — and when the list appears as a
        // page sliding in from the side, an animated scroll runs against that slide over the
        // same fifth of a second, visibly scrolling the day while it is still flying in and
        // risking a short landing on a frame that has not arrived yet.
        DispatchQueue.main.async {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    // Returns the slot 2 hours before the current clock time, so that after scrolling the current
    // moment sits lower on the timeline with context above it.
    //
    // Computed for whichever day is on screen, not only for today. Paging rebuilds the list, so
    // any other day would otherwise open at midnight: look at today around 9am, swipe to
    // tomorrow, and the timeline drops to the small hours instead of staying where the eye was.
    // Anchoring every day at the same clock position keeps the grid still under a swipe.
    private func scrollAnchorSlotID() -> String? {
        guard let section = sections.first else { return nil }

        let calendar = AppTimeZone.calendar
        let now = Date()
        let nowMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        // Clamped, not wrapped: two hours before 00:30 is yesterday evening, and projecting that
        // clock time onto this day would land the user at the bottom of it.
        let anchorMinutes = max(0, nowMinutes - 120)
        let snappedMinutes = (anchorMinutes / slotDurationMinutes) * slotDurationMinutes

        // Built by adding minutes to the day's start, exactly the way the slots themselves are, so
        // the id still matches on a day that gains or loses an hour to DST.
        guard let slotStart = calendar.date(
            byAdding: .minute,
            value: snappedMinutes,
            to: calendar.startOfDay(for: section.date)
        ) else {
            return nil
        }
        return slotID(for: section.date, slotStart: slotStart)
    }
}
