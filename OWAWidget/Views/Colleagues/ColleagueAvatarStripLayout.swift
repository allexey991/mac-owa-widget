import Foundation

/// How many colleague avatars fit in the collapsed section header.
///
/// A fixed cap was showing "+2" while a third of the row sat empty, and it could not know about
/// the wider popover presets either. Everything here is arithmetic on the popover width, so it is
/// testable without a view.
enum ColleagueAvatarStripLayout {
    static let avatarSize: CGFloat = 18
    static let spacing: CGFloat = 3
    /// Room for the "+N" label that replaces the avatars that did not fit.
    static let overflowLabelWidth: CGFloat = 26
    /// Everything in the header that is not avatars: horizontal padding, the person icon, the
    /// section title, the plus and the chevron, plus slack so a longer translation of the title
    /// cannot push the strip into them.
    static let chromeWidth: CGFloat = 170
    /// Beyond this the strip stops being scannable and becomes a wall of initials.
    static let hardCap = 12

    static func visibleCount(totalCount: Int, popoverWidth: CGFloat) -> Int {
        guard totalCount > 0 else { return 0 }
        let available = max(0, popoverWidth - chromeWidth)
        let slot = avatarSize + spacing
        let fits = min(hardCap, Int(available / slot))
        if fits >= totalCount { return totalCount }
        // Overflowing: the "+N" label needs a slot of its own, and at least one face is shown so
        // the row never degenerates into a bare counter.
        return max(1, min(hardCap, Int((available - overflowLabelWidth) / slot)))
    }
}
