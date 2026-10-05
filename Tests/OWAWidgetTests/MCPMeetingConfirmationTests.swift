import XCTest
@testable import OWAWidget

/// The waiting logic behind the confirmation panel, with a fake panel: exactly one answer per
/// question, whatever comes first.
@MainActor
final class MCPMeetingConfirmationTests: XCTestCase {
    private final class FakePresenter: MCPConfirmationPresenting {
        private(set) var shown = 0
        private(set) var closed = 0
        var onConfirm: (() -> Void)?
        var onReject: (() -> Void)?

        func show(_ proposal: MCPMeetingProposal, deadline: Date, onConfirm: @escaping () -> Void, onReject: @escaping () -> Void) {
            shown += 1
            self.onConfirm = onConfirm
            self.onReject = onReject
        }

        func close() { closed += 1 }
    }

    private let proposal = MCPMeetingProposal(
        title: "t", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1800),
        required: [], optional: [], location: "", agenda: "", conflicts: [], client: "", externalCheckAvailable: true
    )

    /// Lets the confirm call reach the point where the panel is on screen.
    private func waitUntilShown(_ presenter: FakePresenter, count: Int = 1) async {
        for _ in 0..<200 where presenter.shown < count {
            await Task.yield()
        }
    }

    func testButtonsAnswerAndClosePanel() async {
        for (press, expected) in [(true, MCPConfirmationOutcome.confirmed), (false, .rejected)] {
            let presenter = FakePresenter()
            let controller = MCPMeetingConfirmationController(presenter: presenter)
            let answer = Task { await controller.confirm(proposal, timeout: 30) }
            await waitUntilShown(presenter)

            press ? presenter.onConfirm?() : presenter.onReject?()

            let outcome = await answer.value
            XCTAssertEqual(outcome, expected)
            XCTAssertEqual(presenter.closed, 1)
        }
    }

    func testNoAnswerTimesOutAndALateClickChangesNothing() async {
        let presenter = FakePresenter()
        let controller = MCPMeetingConfirmationController(presenter: presenter)

        let outcome = await controller.confirm(proposal, timeout: 0.05)

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(presenter.closed, 1)
        // A click on the panel that just closed must not crash on a second resume.
        presenter.onConfirm?()
        XCTAssertEqual(presenter.closed, 1)
    }

    func testClientCancellationClosesThePanel() async {
        let presenter = FakePresenter()
        let controller = MCPMeetingConfirmationController(presenter: presenter)
        let answer = Task { await controller.confirm(proposal, timeout: 30) }
        await waitUntilShown(presenter)

        answer.cancel()

        let outcome = await answer.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(presenter.closed, 1)
    }

    func testClickOnAReplacedQuestionDoesNotAnswerTheNewOne() async {
        let presenter = FakePresenter()
        let controller = MCPMeetingConfirmationController(presenter: presenter)
        let first = Task { await controller.confirm(proposal, timeout: 30) }
        await waitUntilShown(presenter)
        let staleConfirm = presenter.onConfirm

        let second = Task { await controller.confirm(proposal, timeout: 30) }
        await waitUntilShown(presenter, count: 2)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .cancelled)

        staleConfirm?()
        presenter.onReject?()
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .rejected)
    }
}
