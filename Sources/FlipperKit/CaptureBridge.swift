import Foundation
import FlipperProto

/// One button press on the macro pad, in device units.
public struct CaptureTuning: Sendable, Equatable {
    public var frequencyHz: UInt32
    public var windowMs: UInt32

    public static let defaultFrequency: UInt32 = 433_920_000
    public static let defaultWindowMs: UInt32 = 3_000
    /// CC1101 internal radio range, so a preset can actually be tuned there.
    public static let frequencyRange: ClosedRange<UInt32> = 300_000_000...928_000_000
    public static let windowRange: ClosedRange<UInt32> = 200...30_000

    public init(
        frequencyHz: UInt32 = CaptureTuning.defaultFrequency,
        windowMs: UInt32 = CaptureTuning.defaultWindowMs
    ) {
        self.frequencyHz = frequencyHz
        self.windowMs = windowMs
    }
}

/// A frequency the macro pad offers as a one-tap button.
public struct CapturePreset: Sendable, Identifiable, Hashable {
    public let id: UInt32
    public let name: String

    public var frequencyHz: UInt32 { id }

    public static let all: [CapturePreset] = [
        .init(id: 315_000_000, name: "315 MHz"),
        .init(id: 433_920_000, name: "433.92 MHz"),
        .init(id: 868_350_000, name: "868.35 MHz"),
        .init(id: 915_000_000, name: "915 MHz"),
    ]
}

/// What the device reported about one capture.
public struct CaptureResult: Sendable, Equatable {
    /// `.sub` file on the Flipper's SD card, empty when the capture failed.
    public let path: String
    public let pairs: Int
    /// The device's own line, e.g. `ok /ext/subghz/cap_...sub pairs=812`.
    public let raw: String
    public let failure: String?

    public var succeeded: Bool { failure == nil && !path.isEmpty }

    public var fileName: String { path.isEmpty ? "" : (path as NSString).lastPathComponent }
}

/// Newline-framed lines from the bridge, fed from both delivery paths.
///
/// A reply can arrive either as the response to our own data-exchange request or, for the
/// capture-finish push, unsolicited on the message stream. Rather than guess which, both feed
/// this inbox and the caller polls it. A 50 ms poll is far below anything the pad can feel.
private final class CaptureLineInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var lines: [String] = []

    func push(_ data: Data) {
        push(contentsOf: [UInt8](data))
    }

    func push(contentsOf bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        pending.append(contentsOf: bytes)
        while let newline = pending.firstIndex(of: 0x0A) {
            let slice = pending[0..<newline]
            pending.removeFirst(newline + 1)
            let text = String(decoding: slice, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(text) }
        }
        // A wedged half-line must not grow without bound.
        if pending.count > 8 * 1024 { pending.removeAll(keepingCapacity: true) }
        lock.unlock()
    }

    /// Removes and returns everything received so far.
    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let out = lines
        lines.removeAll(keepingCapacity: true)
        return out
    }
}

extension FlipperRPCClient {
    /// Installed by `ufbt launch` from `fap/capture_bridge`; the app category is `Tools`.
    private static let captureBridgePaths = [
        "/ext/apps/Tools/capture_bridge.fap",
        "/ext/apps/Sub-GHz/capture_bridge.fap",
    ]
    private static let pollInterval = Duration.milliseconds(50)

    /// True while a capture owns the RPC app session, so the pad cannot re-enter it.
    /// The setter lives on the client because extensions cannot add storage.
    public var captureBusy: Bool { captureSessionActive }

    /// One-shot: start the bridge, capture, quit. Returns the device's result line.
    ///
    /// The capture needs the app running in RPC mode, because the radio is driven from the device
    /// side. Paying an app start per press keeps the failure modes simple: nothing is left holding
    /// the CC1101 if the phone walks away.
    public func capture(_ tuning: CaptureTuning = CaptureTuning()) async throws -> CaptureResult {
        guard CaptureTuning.frequencyRange.contains(tuning.frequencyHz) else {
            throw FlipperError.rpc(L("Frequency must be between 300 and 928 MHz"))
        }
        guard CaptureTuning.windowRange.contains(tuning.windowMs) else {
            throw FlipperError.rpc(L("Capture window must be between 0.2 and 30 seconds"))
        }
        guard !captureSessionActive else { throw FlipperError.rpc(L("A capture is already running")) }
        captureSessionActive = true
        defer { captureSessionActive = false }

        let inbox = CaptureLineInbox()
        let pump = pumpUnsolicited(into: inbox)
        defer { pump.cancel() }

        do {
            try await startCaptureBridge()
            // `ping` doubles as the readiness gate: if the app was still coming up the first
            // exchange is lost, so one retry is worth more than a fixed sleep.
            if try await exchange("ping", into: inbox).first != "pong" {
                try await Task.sleep(for: .milliseconds(500))
                guard try await exchange("ping", into: inbox).first == "pong" else {
                    throw FlipperError.rpc(L("Capture Bridge did not answer"))
                }
            }
            _ = try await exchange("rx \(tuning.frequencyHz) \(tuning.windowMs)", into: inbox)
        } catch {
            try? await exitApp()
            throw error
        }

        // `started` comes back immediately; `done <result>` is pushed when the window closes.
        // Slack on top of the window covers radio setup and the SD write.
        let deadline = Duration.milliseconds(Int(tuning.windowMs) + 5000)
        let outcome: CaptureResult
        do {
            let line = try await Self.waitForLine(
                in: inbox,
                deadline: deadline,
                matching: { $0.hasPrefix("done ") || $0.hasPrefix("err ") })
            if let line {
                outcome = Self.parse(String(line.dropFirst("done ".count)))
            } else {
                // Window closed with nothing pushed; ask once before giving up.
                let asked = try await exchange("result", into: inbox)
                guard let answer = asked.first, !answer.isEmpty else { throw FlipperError.timeout }
                outcome = Self.parse(answer)
            }
        } catch {
            try? await exitApp()
            throw error
        }
        try? await exitApp()
        return outcome
    }

    /// Cheap liveness check: proves the .fap is installed and speaking the protocol.
    public func captureBridgePing() async throws -> Bool {
        let inbox = CaptureLineInbox()
        let pump = pumpUnsolicited(into: inbox)
        defer { pump.cancel() }
        try await startCaptureBridge()
        defer { Task { try? await self.exitApp() } }
        try await Task.sleep(for: .milliseconds(400))
        let answer = try await exchange("ping", into: inbox)
        return answer.first == "pong"
    }

    private func startCaptureBridge() async throws {
        var lastError: Error?
        for path in Self.captureBridgePaths {
            do {
                try await startApp(name: path, args: "RPC")
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? FlipperError.rpc(L("Capture Bridge is not installed on the Flipper"))
    }

    /// Sends one newline-terminated command and returns whatever came back inline.
    @discardableResult
    private func exchange(_ command: String, into inbox: CaptureLineInbox) async throws -> [String] {
        var request = PBApp_DataExchangeRequest()
        request.data = Data((command + "\n").utf8)
        let parts = try await call(.appDataExchangeRequest(request), timeout: .seconds(10))
        var inline: [String] = []
        for part in parts {
            if case .appDataExchangeRequest(let chunk)? = part.content {
                inbox.push(chunk.data)
                let text = String(decoding: chunk.data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { inline.append(text) }
            }
        }
        return inline
    }

    /// Forwards app data the Flipper sends on its own into the inbox.
    private func pumpUnsolicited(into inbox: CaptureLineInbox) -> Task<Void, Never> {
        let messages = unsolicitedMessages(bufferLimit: 64)
        return Task {
            for await message in messages {
                if case .appDataExchangeRequest(let chunk)? = message.content {
                    inbox.push(chunk.data)
                }
            }
        }
    }

    private static func parse(_ line: String) -> CaptureResult {
        let parts = line.split(separator: " ").map(String.init)
        let pairs = parts.first { $0.hasPrefix("pairs=") }
            .flatMap { Int($0.dropFirst("pairs=".count)) } ?? 0
        if line.hasPrefix("ok ") {
            return CaptureResult(path: parts.count > 1 ? parts[1] : "", pairs: pairs, raw: line, failure: nil)
        }
        return CaptureResult(path: "", pairs: pairs, raw: line, failure: line)
    }

    private static func waitForLine(
        in inbox: CaptureLineInbox,
        deadline: Duration,
        matching predicate: @Sendable (String) -> Bool
    ) async throws -> String? {
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            for line in inbox.drain() where predicate(line) { return line }
            try await Task.sleep(for: pollInterval)
        }
        return inbox.drain().first(where: predicate)
    }
}
