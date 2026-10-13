import SwiftUI
import Yonc

// The whole partner surface in one small app: one downloaded model and Turbo Mode with its
// safe-state and attestation read-outs. `import Yonc` is the only import — the package re-exports
// the Swift facade and the Kotlin-exported types.

@main
struct YoncSampleApp: App {
    @StateObject private var model = SampleModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                ModelsScreen().tabItem { Label("Model", systemImage: "square.and.arrow.down") }
                TurboScreen().tabItem { Label("Turbo", systemImage: "bolt") }
            }
            .environmentObject(model)
        }
    }
}

@MainActor
final class SampleModel: ObservableObject {
    let sdk: Yonc

    @Published var entries: [ModelEntry] = []
    @Published var status = ""
    /// The model the network named as this device's default — what `download()` without an id fetches.
    @Published var defaultModelId: ModelId?

    // Turbo
    @Published var turboStatus = ""
    @Published var turboStats = ""
    @Published var safeState = ""
    /// What Turbo waits for right now, in this app's words (empty while it is not held back).
    @Published var waitingFor: [String] = []
    @Published var attestation = ""
    @Published var attestationFailed = false
    @Published var accountError: String?

    let attested: Bool

    var firstLocal: ModelEntryLocal? { entries.compactMap { $0 as? ModelEntryLocal }.first }

    init() {
        let attestation = Self.attestationConfig()
        attested = attestation != nil
        // The one SDK call a host makes. The handle owns the engine glue, the Kotlin graph and the
        // Turbo background continuation (see BGTaskSchedulerPermittedIdentifiers in project.yml).
        sdk = Yonc.start(name: "yonc-ios-sample", version: "0.5.0", attestation: attestation)

        Task { [weak self] in
            // Loads what is on disk and fetches the catalogue the network offers this device.
            try? await self?.sdk.models.initialize()
            guard let self else { return }
            for await list in self.sdk.models.models {
                self.entries = (list as? [ModelEntry]) ?? []
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await id in self.sdk.models.defaultModelId { self.defaultModelId = id }
        }
        Task { [weak self] in
            guard let self else { return }
            for await s in self.sdk.turbo.status { self.turboStatus = "\(s)" }
        }
        Task { [weak self] in
            guard let self else { return }
            for await s in self.sdk.turbo.stats {
                self.turboStats = "tasks \(s.tasksDone) · tokens \(s.tokensGenerated)"
                    + (s.lastHalt.map { " · last halt: \($0)" } ?? "")
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await s in self.sdk.turbo.safeState {
                self.safeState = "charging \(s.isCharging) · wifi \(s.isWifi) · safe \(s.isSafe)"
                // The SDK names the conditions that fail under THIS platform's rules (iOS never asks
                // for a locked screen) — show these rather than re-deriving them from the signals.
                self.waitingFor = s.unmet.map(conditionLabel).sorted()
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await a in self.sdk.turbo.attestation {
                self.attestation = "\(a)"
                self.attestationFailed = a is AttestationState.Failed
            }
        }
    }

    /// Device attestation for Turbo is switched on by supplying the application id YOnC issued for
    /// this bundle id + team and the current user's opaque id. This sample reads both from launch
    /// arguments (-yoncApplicationId / -yoncReportingId) or Info.plist (filled by the build
    /// settings YONC_APPLICATION_ID / YONC_EXTERNAL_REPORTING_ID); a real app passes the signed-in
    /// user's id. Empty = the device connects unattested, which the network admits only while
    /// enforcement is off for the application.
    private static func attestationConfig() -> AttestationConfig? {
        let defaults = UserDefaults.standard
        let applicationId = defaults.string(forKey: "yoncApplicationId")
            ?? (Bundle.main.object(forInfoDictionaryKey: "YoncApplicationId") as? String) ?? ""
        let reportingId = defaults.string(forKey: "yoncReportingId")
            ?? (Bundle.main.object(forInfoDictionaryKey: "YoncExternalReportingId") as? String) ?? ""
        guard !applicationId.isEmpty, !reportingId.isEmpty else { return nil }
        return AttestationConfig(applicationId: applicationId, externalReportingId: reportingId)
    }

    /// The one-button path: the model the network designates as default for this device.
    func downloadDefault() {
        status = "downloading the default model…"
        Task {
            do {
                try await sdk.models.download()
                status = "default model downloaded"
            } catch { status = "download failed: \(error.localizedDescription)" }
        }
    }

    func download(_ info: ModelInfo) {
        status = "downloading \(info.name)…"
        Task {
            do {
                try await sdk.models.download(modelId: info.id)
                status = "downloaded \(info.name)"
            } catch { status = "download failed: \(error.localizedDescription)" }
        }
    }

    func delete(_ info: ModelInfo) {
        Task {
            try? await sdk.models.delete(modelId: info.id)
            status = "deleted \(info.name)"
        }
    }

    /// Nothing to pass: the device offers every downloaded model and the network picks which one
    /// runs. Switched on before a download finished, Turbo waits for the first model.
    func toggleTurbo() {
        if turboStatus.lowercased().contains("off") { sdk.turbo.start() } else { sdk.turbo.stop() }
    }

    /// After a sticky attestation refusal the SDK stops retrying by itself; this is the user's say-so.
    func retryAttestation() {
        sdk.turbo.retryAttestation()
    }

    /// The user signed in to another account: the network credits the new label from now on. Turbo
    /// leaves its connection at once and reconnects under it. A real app also passes the current
    /// label to `Yonc.start` on every launch.
    func switchAccount(to label: String) {
        do {
            try sdk.turbo.setReportingLabel(label: label)
            accountError = nil
        } catch {
            accountError = "The network would reject this label: \(error.localizedDescription)"
        }
    }
}

/// What the user does about each condition. Later SDK releases may add conditions: keep the default.
func conditionLabel(_ condition: SafeCondition) -> String {
    switch condition {
    case .charging: return "Plug in the charger"
    case .wifi: return "Connect to Wi-Fi"
    case .screenLocked: return "Lock the screen"
    case .thermal: return "Let the phone cool down"
    case .backgroundWork: return "Allow background running"
    @unknown default: return "\(condition)"
    }
}

/// `tier · quant · size`. The SDK hands out bytes; units and rounding are the app's.
func describe(_ info: ModelInfo) -> String {
    let size = info.sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: info.sizeBytes, countStyle: .file) : ""
    return [info.tier, info.quant, size].filter { !$0.isEmpty }.joined(separator: " · ")
}

struct ModelsScreen: View {
    @EnvironmentObject var model: SampleModel

    var body: some View {
        NavigationStack {
            List {
                if model.firstLocal == nil {
                    Button("Download the default model") { model.downloadDefault() }
                }
                ForEach(model.entries, id: \.info.name) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(entry.info.name).font(.headline)
                                if entry.info.id == model.defaultModelId {
                                    Text("Default").font(.caption2).foregroundStyle(.tint)
                                }
                            }
                            Text(describe(entry.info)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let downloading = entry as? ModelEntryDownloading {
                            VStack(alignment: .trailing) {
                                ProgressView(value: Double(downloading.progress))
                                    .frame(width: 80)
                                if downloading.totalBytes > 0 {
                                    Text("\(ByteCountFormatter.string(fromByteCount: downloading.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: downloading.totalBytes, countStyle: .file))")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else if entry is ModelEntryLocal {
                            Button("Delete", role: .destructive) { model.delete(entry.info) }
                        } else {
                            Button("Get") { model.download(entry.info) }
                        }
                    }
                }
                if !model.status.isEmpty {
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Model")
        }
    }
}

struct TurboScreen: View {
    @EnvironmentObject var model: SampleModel

    var body: some View {
        NavigationStack {
            List {
                Section("Worker") {
                    Text("status: \(model.turboStatus)")
                    Text(model.turboStats).font(.caption.monospaced())
                    Text(model.safeState).font(.caption.monospaced())
                    Button(model.turboStatus.lowercased().contains("off") ? "Start" : "Stop") {
                        model.toggleTurbo()
                    }
                }
                if !model.waitingFor.isEmpty {
                    Section("Waiting for") {
                        ForEach(model.waitingFor, id: \.self) { Text($0) }
                    }
                }
                Section("Attestation") {
                    Text(model.attestation).font(.caption.monospaced())
                    if model.attestationFailed {
                        Button("Retry attestation") { model.retryAttestation() }
                    }
                }
                if model.attested {
                    AccountSection()
                }
                Section {
                    Text("Turbo serves tasks while the device is charging, on Wi-Fi and cool. When the screen locks, the SDK asks iOS for a continued-processing window (a visible progress pill) to keep serving; iOS may deny or end it at any time. Attestation needs a physical device — the simulator reports Unavailable and connects unattested.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Turbo")
        }
    }
}

/// The account the network credits; shown only when the sample runs with attestation.
struct AccountSection: View {
    @EnvironmentObject var model: SampleModel
    @State private var label = UserDefaults.standard.string(forKey: "yoncReportingId") ?? ""

    var body: some View {
        Section("Account") {
            TextField("Account label", text: $label)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Switch account") { model.switchAccount(to: label) }
            if let error = model.accountError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
