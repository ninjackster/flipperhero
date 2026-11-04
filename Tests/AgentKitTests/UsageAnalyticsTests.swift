import XCTest
@testable import AgentKit

final class UsageAnalyticsTests: XCTestCase {
    func testPayloadContainsOnlyFixedUsageMetadata() throws {
        let data = try RybbitUsageAnalytics.payload(siteID: "60", version: "1.0", edition: "store",
            sessionID: "temporary-session", path: "/agent", event: .agent_completed)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), Set(["site_id", "type", "hostname", "pathname", "anonymous_id", "properties", "event_name"]))
        XCTAssertEqual(payload["site_id"] as? String, "60")
        XCTAssertEqual(payload["event_name"] as? String, "agent_completed")
        let properties = try XCTUnwrap((payload["properties"] as? String)?.data(using: .utf8))
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: properties) as? [String: String])
        XCTAssertEqual(values, ["version": "1.0", "edition": "store"])
    }

    func testAgentCannotEnableAnalyticsWithoutConsentEvenInYoloMode() async {
        let controls = FakeAppControls()
        let gate = ScriptedGate(answer: false)
        let executor = ToolExecutor(flipper: FakeFlipper(), gate: gate, audit: InMemoryAuditLog(),
            appControls: controls, settings: { ApprovalSettings(autoApproveMedium: true, yolo: true, yoloAsksAfterUntrusted: false) })
        let result = await executor.execute(ToolCall(id: "analytics", name: "set_usage_analytics", arguments: #"{"enabled":true}"#))
        XCTAssertEqual(result.kind, .denied)
        XCTAssertEqual(gate.requests.count, 1)
        let enabled = await controls.state.usageAnalytics
        XCTAssertFalse(enabled)
    }
}
