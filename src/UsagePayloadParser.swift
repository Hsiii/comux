import Foundation

enum UsagePayloadParser {
    static func parse(
        data: Data,
        response: URLResponse?
    ) throws -> [String: Any] {
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw PulseError.invalidUsageResponse
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PulseError.invalidUsageResponse
        }

        if payload["error"] != nil, payload["rate_limit"] as? [String: Any] == nil {
            throw PulseError.invalidUsageResponse
        }

        let hasIdentityFields = payload["account_id"] != nil
            || payload["email"] != nil
            || payload["plan_type"] != nil
        let hasUsageFields = payload["rate_limit"] as? [String: Any] != nil

        guard hasIdentityFields || hasUsageFields else {
            throw PulseError.invalidUsageResponse
        }

        return payload
    }
}
