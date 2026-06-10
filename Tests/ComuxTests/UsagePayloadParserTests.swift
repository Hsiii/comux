import XCTest
@testable import Comux

final class UsagePayloadParserTests: XCTestCase {
    func testRejectsNonSuccessStatusEvenWhenBodyIsJSON() throws {
        let data = try self.jsonData([
            "error": [
                "message": "unauthorized"
            ]
        ])
        let response = HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )

        XCTAssertThrowsError(
            try UsagePayloadParser.parse(
                data: data,
                response: response
            )
        ) { error in
            XCTAssertEqual(error as? PulseError, .invalidUsageResponse)
        }
    }

    func testRejectsErrorPayloadsWithoutUsageFields() throws {
        let data = try self.jsonData([
            "error": [
                "message": "forbidden"
            ]
        ])
        let response = HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        XCTAssertThrowsError(
            try UsagePayloadParser.parse(
                data: data,
                response: response
            )
        ) { error in
            XCTAssertEqual(error as? PulseError, .invalidUsageResponse)
        }
    }

    func testAcceptsUsagePayloadWithExpectedFields() throws {
        let data = try self.jsonData([
            "account_id": "workspace-a",
            "email": "person@example.com",
            "plan_type": "team",
            "rate_limit": [
                "primary_window": [
                    "limit_window_seconds": 18_000,
                    "reset_at": 1_000,
                    "used_percent": 50
                ]
            ]
        ])
        let response = HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )

        let payload = try UsagePayloadParser.parse(
            data: data,
            response: response
        )

        XCTAssertEqual(payload["account_id"] as? String, "workspace-a")
        XCTAssertEqual(payload["email"] as? String, "person@example.com")
    }

    private func jsonData(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }
}
