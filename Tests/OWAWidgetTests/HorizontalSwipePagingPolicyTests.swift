import XCTest
@testable import OWAWidget

final class HorizontalSwipePagingPolicyTests: XCTestCase {
    private let threshold = HorizontalSwipePagingPolicy.threshold

    func testTravelBelowThresholdDoesNotPage() {
        var policy = HorizontalSwipePagingPolicy()
        policy.begin()

        XCTAssertNil(policy.accumulate(deltaX: threshold - 1, deltaY: 0, timestamp: 0))
    }

    func testSmallDeltasAccumulateIntoOneStep() {
        var policy = HorizontalSwipePagingPolicy()
        policy.begin()

        let chunk = threshold / 4
        var steps: [HorizontalSwipePagingPolicy.Step] = []
        for index in 0..<4 {
            if let step = policy.accumulate(deltaX: -chunk, deltaY: 0, timestamp: Double(index) * 0.02) {
                steps.append(step)
            }
        }

        XCTAssertEqual(steps, [.next])
    }

    func testPositiveTravelGoesToPreviousDay() {
        var policy = HorizontalSwipePagingPolicy()
        policy.begin()

        XCTAssertEqual(policy.accumulate(deltaX: threshold, deltaY: 0, timestamp: 0), .previous)
    }

    func testNegativeTravelGoesToNextDay() {
        var policy = HorizontalSwipePagingPolicy()
        policy.begin()

        XCTAssertEqual(policy.accumulate(deltaX: -threshold, deltaY: 0, timestamp: 0), .next)
    }

    /// One flick is one day: a long swipe must not run through a week.
    func testOneGesturePagesOnlyOnce() {
        var policy = HorizontalSwipePagingPolicy()
        policy.begin()

        XCTAssertEqual(policy.accumulate(deltaX: threshold, deltaY: 0, timestamp: 0), .previous)
        XCTAssertNil(policy.accumulate(deltaX: threshold, deltaY: 0, timestamp: 0.02))
        XCTAssertNil(policy.accumulate(deltaX: threshold * 4, deltaY: 0, timestamp: 0.04))
    }

    func testNextGestureAfterEndPagesAgain() {
        var policy = HorizontalSwipePagingPolicy()
        policy.begin()
        XCTAssertEqual(policy.accumulate(deltaX: threshold, deltaY: 0, timestamp: 0), .previous)
        policy.end()

        policy.begin()
        XCTAssertEqual(policy.accumulate(deltaX: threshold, deltaY: 0, timestamp: 0.1), .previous)
    }

    /// A phase-less wheel never reports an end, so a pause is what separates two gestures.
    func testIdlePauseRearmsWithoutAnExplicitEnd() {
        var policy = HorizontalSwipePagingPolicy()
        XCTAssertEqual(policy.accumulate(deltaX: threshold, deltaY: 0, timestamp: 0), .previous)
        XCTAssertNil(policy.accumulate(deltaX: threshold, deltaY: 0, timestamp: 0.05))

        let afterPause = HorizontalSwipePagingPolicy.idleResetInterval + 0.1
        XCTAssertEqual(policy.accumulate(deltaX: threshold, deltaY: 0, timestamp: afterPause), .previous)
    }

    /// Scrolling the timeline drifts sideways a little; that must not flip the date.
    func testVerticalScrollWithSidewaysDriftDoesNotPage() {
        var policy = HorizontalSwipePagingPolicy()
        policy.begin()

        var timestamp = 0.0
        for _ in 0..<10 {
            XCTAssertNil(policy.accumulate(deltaX: 8, deltaY: -40, timestamp: timestamp))
            timestamp += 0.02
        }
    }

    func testHorizontalTravelMustOutrunVerticalTravel() {
        var policy = HorizontalSwipePagingPolicy()
        policy.begin()

        // Past the distance threshold, but not dominant enough to be a swipe.
        let vertical = threshold / HorizontalSwipePagingPolicy.horizontalDominance
        XCTAssertNil(policy.accumulate(deltaX: threshold, deltaY: vertical, timestamp: 0))
    }

    func testBeginDiscardsTravelLeftByThePreviousGesture() {
        var policy = HorizontalSwipePagingPolicy()
        XCTAssertNil(policy.accumulate(deltaX: threshold - 1, deltaY: 0, timestamp: 0))

        policy.begin()
        XCTAssertNil(policy.accumulate(deltaX: threshold - 1, deltaY: 0, timestamp: 0.02))
    }
}
