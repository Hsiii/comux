import XCTest
@testable import Comux

final class FormatTests: XCTestCase {
    func testUnavailableUsageWindowShowsNoSeatText() {
        let window = UsageWindow(
            available: false,
            label: "Weekly window",
            usedMinutes: 0,
            limitMinutes: 0,
            usedPercentage: 0,
            resetsAt: ""
        )

        XCTAssertEqual(percentageText(for: window), "No seat")
        XCTAssertEqual(resetPaceText(for: window), "No usage access")
    }
}
