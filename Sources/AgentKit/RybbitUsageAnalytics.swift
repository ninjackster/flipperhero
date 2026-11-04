import Foundation

/// A fixed event vocabulary keeps conversation and device content out of analytics.
public actor RybbitUsageAnalytics {
    public enum Screen: String, Sendable, CaseIterable { case device, remote, files, agent, settings }
    public enum Event: String, Sendable { case app_open, agent_completed, agent_failed }
    private let siteID: String
    private let version: String
    private let edition: String
    private let session: URLSession
    private var enabled: Bool
    private var sessionID = UUID().uuidString

    public init(siteID: String, version: String, edition: String, enabled: Bool, session: URLSession = .shared) {
        self.siteID = siteID
        self.version = version
        self.edition = edition
        self.enabled = enabled
        self.session = session
    }

    public func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        sessionID = UUID().uuidString
    }

    public func screen(_ screen: Screen) async { await send(path: "/\(screen.rawValue)", event: nil) }
    public func event(_ event: Event) async { await send(path: "/app", event: event) }

    private func send(path: String, event: Event?) async {
        guard enabled else { return }
        var request = URLRequest(url: URL(string: "https://stats.2342.dev/api/track")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        request.setValue("FlipperHero/\(version) (iOS \(os.majorVersion).\(os.minorVersion))", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? Self.payload(siteID: siteID, version: version, edition: edition,
                                            sessionID: sessionID, path: path, event: event)
        guard request.httpBody != nil else { return }
        _ = try? await session.data(for: request)
    }

    static func payload(siteID: String, version: String, edition: String, sessionID: String,
                        path: String, event: Event?) throws -> Data {
        let properties = try JSONSerialization.data(withJSONObject: ["version": version, "edition": edition])
        var payload: [String: Any] = [
            "site_id": siteID, "type": event == nil ? "pageview" : "custom_event",
            "hostname": "ios.flipper-hero.net", "pathname": path, "anonymous_id": sessionID,
            "properties": String(decoding: properties, as: UTF8.self),
        ]
        if let event { payload["event_name"] = event.rawValue }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
