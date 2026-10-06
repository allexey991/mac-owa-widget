import SwiftUI

/// The New Meeting window's root: picks the Exchange account the form works with. That is the
/// first account able to create meetings, unless a draft from an AI assistant asked for another
/// one; `.id` rebuilds the form, with its own view model, when the account changes.
struct CreateMeetingWindowContent: View {
    @ObservedObject var calendarService: CalendarService
    @State private var requestedAccountID: UUID?

    var body: some View {
        // A container that stays put while the form inside is rebuilt for another account:
        // its `onDisappear` fires only when the window closes.
        ZStack {
            if let account {
                CreateMeetingView(calendarService: calendarService, accountID: account.id) { requested in
                    requestedAccountID = requested
                }
                .id(account.id)
            }
        }
        .onDisappear {
            // The window opened by hand next time starts on the default account again.
            requestedAccountID = nil
        }
    }

    private var account: CalendarAccount? {
        if let requestedAccountID,
           let requested = calendarService.accounts.first(where: {
               $0.id == requestedAccountID && $0.accountType.supportsMeetingCreation
           }) {
            return requested
        }
        return calendarService.meetingCreationAccount
    }
}
