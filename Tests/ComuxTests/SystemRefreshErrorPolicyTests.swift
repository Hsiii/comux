import XCTest
@testable import Comux

final class SystemRefreshErrorPolicyTests: XCTestCase {
    func testTreatsInvalidAuthFileAsRefreshedSystemState() {
        XCTAssertTrue(
            SystemRefreshErrorPolicy.shouldTreatAsRefreshedSystemState(
                PulseError.invalidAuthFile
            )
        )
    }

    func testDoesNotTreatWorkspaceListFailureAsRefreshedSystemState() {
        XCTAssertFalse(
            SystemRefreshErrorPolicy.shouldTreatAsRefreshedSystemState(
                PulseError.workspaceListUnavailable
            )
        )
    }

    func testDoesNotTreatNonPulseErrorsAsRefreshedSystemState() {
        XCTAssertFalse(
            SystemRefreshErrorPolicy.shouldTreatAsRefreshedSystemState(
                NSError(domain: "ComuxTests", code: 1)
            )
        )
    }
}
