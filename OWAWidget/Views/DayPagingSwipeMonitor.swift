import SwiftUI
import AppKit

/// Turns a stream of horizontal scroll deltas into at most one page step per gesture.
///
/// Kept free of AppKit so the thresholds can be tested directly. The rules it encodes:
///
/// - a gesture pages **once**; a long swipe is still one day, not five;
/// - horizontal travel must clearly beat vertical travel, otherwise a slightly slanted scroll
///   through the timeline would start flipping dates under the user;
/// - a pause re-arms the accumulator, which is what makes a classic (phase-less) mouse wheel
///   behave like a trackpad gesture.
struct HorizontalSwipePagingPolicy {
    enum Step: Equatable {
        case previous
        case next
    }

    /// Accumulated horizontal travel, in points, that completes one page.
    static let threshold: CGFloat = 40
    /// How far horizontal travel must outrun vertical travel to count as a swipe.
    static let horizontalDominance: CGFloat = 1.5
    /// Quiet time after which the next delta starts a fresh gesture.
    static let idleResetInterval: TimeInterval = 0.25

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var isArmed = true
    private var lastTimestamp: TimeInterval?

    /// Fingers touched down: whatever the previous gesture left behind is stale.
    mutating func begin() {
        reset()
    }

    /// Fingers lifted (or the gesture was cancelled).
    mutating func end() {
        reset()
    }

    mutating func accumulate(deltaX: CGFloat, deltaY: CGFloat, timestamp: TimeInterval) -> Step? {
        if let lastTimestamp, timestamp - lastTimestamp > Self.idleResetInterval {
            reset()
        }
        lastTimestamp = timestamp
        accumulatedX += deltaX
        accumulatedY += deltaY

        guard isArmed else { return nil }
        guard abs(accumulatedX) >= Self.threshold else { return nil }
        guard abs(accumulatedX) > abs(accumulatedY) * Self.horizontalDominance else { return nil }

        // Same convention as back/forward in Safari and Finder: content pushed to the right
        // reveals what lies before it.
        let step: Step = accumulatedX > 0 ? .previous : .next
        isArmed = false
        accumulatedX = 0
        accumulatedY = 0
        return step
    }

    private mutating func reset() {
        accumulatedX = 0
        accumulatedY = 0
        isArmed = true
        lastTimestamp = nil
    }
}

/// Tactile answer to a swipe, for trackpads that can give one. A swipe leaves no button to
/// light up and no cursor to follow, so the tick is often the clearest confirmation the user
/// gets that the gesture landed. Silent on hardware without a Force Touch trackpad, which is why
/// it stays an addition to the on-screen slide rather than a replacement for it.
@MainActor
enum DayPagingHaptics {
    static func pageTurned() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// A swipe past the first or last day. Deliberately a different, blunter pattern: the point
    /// is to say "there is nothing there", not to mimic a successful turn.
    static func pageRefused() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

/// Opaque monitor token, for the same reason as in `EscapeKeyMonitor`: `NSEvent`'s monitor object
/// is only ever handed back to AppKit.
private struct ScrollMonitorToken: @unchecked Sendable {
    let value: Any
}

/// Owns the local scroll monitor. A reference type for the same reason as `EscapeKeyMonitorBox`:
/// the closures live in mutable properties that every render refreshes.
@MainActor
private final class DayPagingSwipeMonitorBox: ObservableObject {
    var isEnabled: () -> Bool = { false }
    var action: (HorizontalSwipePagingPolicy.Step) -> Void = { _ in }

    private var policy = HorizontalSwipePagingPolicy()
    /// Stored wrapped rather than as a bare `Any?`: `deinit` is nonisolated, and only a
    /// `Sendable` property may be read there.
    private var monitor: ScrollMonitorToken?

    func install() {
        guard monitor == nil else { return }
        let installed = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            // Swallowed only on the delta that actually paged, so every other scroll event
            // still reaches the timeline underneath.
            return nil
        }
        monitor = installed.map(ScrollMonitorToken.init(value:))
    }

    func remove() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor.value)
        self.monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Momentum is the coast after the fingers lift. Letting it through would page several
        // days from a single flick.
        guard event.momentumPhase.isEmpty else { return false }

        if event.phase.contains(.began) {
            policy.begin()
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            policy.end()
            return false
        }

        guard isEnabled() else { return false }

        // The monitor is app-wide; settings and create-meeting windows scroll on their own.
        guard let popoverWindow = PostJoinDismissController.shared.registeredPopoverWindow,
              event.window === popoverWindow else { return false }

        // The all-day strip scrolls horizontally itself. Whatever is under the pointer and can
        // consume the gesture outranks day paging.
        guard !Self.pointerIsOverHorizontalScroller(in: popoverWindow, at: event.locationInWindow) else {
            return false
        }

        // A classic wheel reports lines, not points, so its deltas are an order of magnitude
        // smaller than a trackpad's and would never reach the threshold unscaled.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        guard let step = policy.accumulate(
            deltaX: event.scrollingDeltaX * scale,
            deltaY: event.scrollingDeltaY * scale,
            timestamp: event.timestamp
        ) else { return false }

        action(step)
        return true
    }

    /// Walks the scroll views enclosing the hit-tested view, outwards, looking for one whose
    /// content is wider than its clip view — the only ones that have somewhere to scroll.
    private static func pointerIsOverHorizontalScroller(in window: NSWindow, at point: NSPoint) -> Bool {
        var candidate = window.contentView?.hitTest(point)?.enclosingScrollView
        while let scrollView = candidate {
            let documentWidth = scrollView.documentView?.frame.width ?? 0
            if documentWidth > scrollView.contentSize.width + 1 { return true }
            candidate = scrollView.superview?.enclosingScrollView
        }
        return false
    }

    /// Backstop for a view that never receives `onDisappear`; see `EscapeKeyMonitorBox.deinit`.
    deinit {
        guard let token = monitor else { return }
        if Thread.isMainThread {
            NSEvent.removeMonitor(token.value)
        } else {
            DispatchQueue.main.async { NSEvent.removeMonitor(token.value) }
        }
    }
}

/// Pages by one day when the user swipes horizontally anywhere over the popover.
///
/// A two-finger trackpad swipe on macOS is not a `DragGesture` — it arrives as `scrollWheel`
/// events, which SwiftUI offers no hook for. A local event monitor sees them wherever they land,
/// and passes on everything it does not consume, so vertical scrolling is untouched.
private struct DayPagingSwipeMonitor: ViewModifier {
    let isEnabled: () -> Bool
    let action: (HorizontalSwipePagingPolicy.Step) -> Void

    @StateObject private var box = DayPagingSwipeMonitorBox()

    func body(content: Content) -> some View {
        // Plain (non-published) properties: assigning during an update publishes nothing and
        // cannot feed back into the render loop.
        box.isEnabled = isEnabled
        box.action = action
        return content
            .onAppear { box.install() }
            .onDisappear { box.remove() }
    }
}

extension View {
    func onHorizontalPagingSwipe(
        isEnabled: @escaping () -> Bool,
        perform action: @escaping (HorizontalSwipePagingPolicy.Step) -> Void
    ) -> some View {
        modifier(DayPagingSwipeMonitor(isEnabled: isEnabled, action: action))
    }
}
