import XCTest
@testable import OWAWidget

/// The collapsed header used to cut the avatar strip at a fixed six, which showed "+2" with a
/// third of the row still empty and ignored the wider popover presets entirely.
final class ColleagueAvatarStripLayoutTests: XCTestCase {
    private let compact = PopoverSize.Preset.compact.size.width
    private let large = PopoverSize.Preset.large.size.width

    func testEveryoneIsShownWhenTheyFit() {
        XCTAssertEqual(ColleagueAvatarStripLayout.visibleCount(totalCount: 5, popoverWidth: compact), 5)
    }

    func testCompactPopoverFitsMoreThanTheOldFixedCap() {
        XCTAssertGreaterThan(ColleagueAvatarStripLayout.visibleCount(totalCount: 30, popoverWidth: compact), 6)
    }

    func testWiderPopoverFitsAtLeastAsMany() {
        let onCompact = ColleagueAvatarStripLayout.visibleCount(totalCount: 30, popoverWidth: compact)
        let onLarge = ColleagueAvatarStripLayout.visibleCount(totalCount: 30, popoverWidth: large)

        XCTAssertGreaterThanOrEqual(onLarge, onCompact)
    }

    /// Overflow costs a slot: the "+N" label has to fit too.
    func testOverflowLeavesRoomForTheCounter() {
        let exactFit = ColleagueAvatarStripLayout.visibleCount(totalCount: 100, popoverWidth: compact)
        let plain = ColleagueAvatarStripLayout.visibleCount(
            totalCount: exactFit,
            popoverWidth: compact
        )

        XCTAssertEqual(plain, exactFit)
        XCTAssertLessThan(exactFit, ColleagueAvatarStripLayout.hardCap + 1)
    }

    func testDegenerateInputs() {
        XCTAssertEqual(ColleagueAvatarStripLayout.visibleCount(totalCount: 0, popoverWidth: compact), 0)
        XCTAssertEqual(ColleagueAvatarStripLayout.visibleCount(totalCount: 9, popoverWidth: 100), 1)
    }
}
