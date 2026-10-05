import AppKit
import SwiftUI

/// A meeting an MCP client asked to create, as the user sees it before anything is sent.
struct MCPMeetingProposal: Equatable, Sendable {
    struct Attendee: Equatable, Sendable {
        let email: String
        let name: String?
        /// Outside the user's own mail domain. `false` when the domain is unknown: the address is
        /// on screen either way.
        let isExternal: Bool
    }

    struct Conflict: Equatable, Sendable {
        let title: String
        let start: Date
        let end: Date
    }

    let title: String
    let start: Date
    let end: Date
    let required: [Attendee]
    let optional: [Attendee]
    let location: String
    let agenda: String
    let conflicts: [Conflict]
    /// The MCP client that asked ("Claude Code"), empty when unknown.
    let client: String
}

enum MCPConfirmationOutcome: Equatable, Sendable {
    case confirmed
    case rejected
    case timedOut
    /// The client cancelled the request (`notifications/cancelled`) or disconnected.
    case cancelled
}

/// Asks the user, in OWA Widget's own window, whether to go ahead. The answer never comes from
/// the MCP client: a model can be talked into anything by a meeting description it has read.
@MainActor
protocol MCPMeetingConfirming: AnyObject {
    func confirm(_ proposal: MCPMeetingProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome
}

/// Floating panel with "Create" and "Cancel". One at a time: a second request while one is on
/// screen is refused by `MCPCalendarTools` before it gets here.
@MainActor
final class MCPMeetingConfirmationController: MCPMeetingConfirming {
    private var panel: NSPanel?
    private var pending: CheckedContinuation<MCPConfirmationOutcome, Never>?
    private var timeoutTask: Task<Void, Never>?

    func confirm(_ proposal: MCPMeetingProposal, timeout: TimeInterval) async -> MCPConfirmationOutcome {
        // A previous request still on screen loses: only one answer can be pending.
        finish(.cancelled)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                pending = continuation
                show(proposal, timeout: timeout)
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    self?.finish(.timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.cancelled) }
        }
    }

    private func finish(_ outcome: MCPConfirmationOutcome) {
        timeoutTask?.cancel()
        timeoutTask = nil
        panel?.close()
        panel = nil
        let continuation = pending
        pending = nil
        continuation?.resume(returning: outcome)
        if continuation != nil {
            MCPDebugLog.log("create_meeting confirmation: \(outcome)")
        }
    }

    private func show(_ proposal: MCPMeetingProposal, timeout: TimeInterval) {
        let localization = LocalizationService()
        let view = MCPMeetingConfirmationView(
            proposal: proposal,
            deadline: Date().addingTimeInterval(timeout),
            localization: localization,
            onConfirm: { [weak self] in self?.finish(.confirmed) },
            onReject: { [weak self] in self?.finish(.rejected) }
        )
        .environment(\.locale, localization.locale)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let hosting = ConfirmationFirstMouseHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        panel.setContentSize(NSSize(width: max(400, fitting.width), height: max(160, fitting.height)))

        // Centre of the screen, like the join picker: this one is waiting for a decision.
        if let screen = NotificationScreenPolicy.current.resolve() {
            let visible = screen.visibleFrame
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
        }
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }
}

private final class ConfirmationFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
