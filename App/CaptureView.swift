import SwiftUI
import FlipperKit

/// The macro pad. One tap sends `rx <freq> <ms>` to the bridge app on the Flipper and waits for
/// the resulting `.sub` file. Deliberately dumb: the device does the radio work, this only aims it.
struct CaptureView: View {
    @Environment(AppModel.self) private var model
    @State private var selected = CapturePreset.all[1]
    @State private var windowMs: UInt32 = CaptureTuning.defaultWindowMs
    @State private var running = false
    @State private var result: CaptureResult?
    @State private var error: String?
    @State private var history: [CaptureResult] = []

    private static let windows: [(label: String, ms: UInt32)] = [
        ("0.5 s", 500), ("1 s", 1_000), ("2 s", 2_000), ("3 s", 3_000), ("5 s", 5_000),
    ]

    var body: some View {
        NavigationStack {
            List {
                padSection
                windowSection
                if let result { outcomeSection(result) }
                if let error { errorSection(error) }
                if !history.isEmpty { historySection }
            }
            .themedList()
            .brandedNavigation("Capture")
        }
    }

    // MARK: - Sections

    private var padSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(CapturePreset.all) { preset in
                    Button { selected = preset } label: {
                        VStack(spacing: 4) {
                            Text(preset.name).font(.headline)
                            Text(preset.frequencyHz == selected.frequencyHz ? "selected" : " ")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 62)
                        .background(
                            preset == selected ? Theme.orange.opacity(0.22) : Color.white.opacity(0.05),
                            in: .rect(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(preset == selected ? Theme.orange.opacity(0.6) : Theme.stroke))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(preset == selected ? Theme.orange : .primary)
                    .disabled(running)
                }
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))

            Button {
                Task { await run() }
            } label: {
                HStack {
                    if running { ProgressView().tint(.white) } else { Image(systemName: "dot.radiowaves.left.and.right") }
                    Text(running ? "Listening..." : "Capture \(selected.name)")
                        .font(.headline)
                    Spacer()
                    Text(Self.windowLabel(windowMs)).font(.subheadline.monospacedDigit()).opacity(0.8)
                }
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(running ? Theme.orange.opacity(0.5) : Theme.orange, in: .rect(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(running || !model.isConnected)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
        } header: {
            Text("Sub-GHz")
        } footer: {
            Text(model.isConnected
                 ? "Press Capture, then press your remote. RAW capture, saved on the Flipper."
                 : "Connect to a Flipper on the Device tab first.")
        }
    }

    private var windowSection: some View {
        Section("Window") {
            Picker("Length", selection: $windowMs) {
                ForEach(Self.windows, id: \.ms) { Text($0.label).tag($0.ms) }
            }
            .pickerStyle(.segmented)
            .disabled(running)
        }
    }

    private func outcomeSection(_ result: CaptureResult) -> some View {
        Section("Last capture") {
            if result.succeeded {
                LabeledContent("File", value: result.fileName)
                LabeledContent("Pairs", value: "\(result.pairs)")
                LabeledContent("Folder", value: "/ext/subghz")
            } else {
                Label(result.raw, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private func errorSection(_ text: String) -> some View {
        Section {
            Label(text, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
        }
    }

    private var historySection: some View {
        Section("This session") {
            ForEach(history, id: \.path) { item in
                HStack {
                    Text(item.fileName).font(.footnote.monospaced())
                    Spacer()
                    Text("\(item.pairs)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Action

    private func run() async {
        guard let client = model.client, !running else { return }
        running = true
        error = nil
        do {
            let outcome = try await client.capture(CaptureTuning(frequencyHz: selected.frequencyHz, windowMs: windowMs))
            result = outcome
            if outcome.succeeded { history.insert(outcome, at: 0) }
        } catch {
            self.error = (error as? FlipperError)?.description ?? error.localizedDescription
        }
        running = false
    }

    private static func windowLabel(_ ms: UInt32) -> String {
        ms % 1000 == 0 ? "\(ms / 1000) s" : String(format: "%.1f s", Double(ms) / 1000)
    }
}
