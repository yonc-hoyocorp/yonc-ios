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

    // Turbo
    @Published var turboStatus = ""
    @Published var turboStats = ""
    @Published var safeState = ""
    @Published var attestation = ""
    @Published var attestationFailed = false

    var firstLocal: ModelEntryLocal? { entries.compactMap { $0 as? ModelEntryLocal }.first }

    init() {
        // The one SDK call a host makes. The handle owns the engine glue, the Kotlin graph and the
        // Turbo background continuation (see BGTaskSchedulerPermittedIdentifiers in project.yml).
        sdk = Yonc.start(name: "yonc-ios-sample", version: "0.1.0", attestation: Self.attestationConfig())

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
                            Text(entry.info.name).font(.headline)
                            Text(entry.info.spec).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let downloading = entry as? ModelEntryDownloading {
                            ProgressView(value: Double(downloading.progress))
                                .frame(width: 80)
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
                Section("Attestation") {
                    Text(model.attestation).font(.caption.monospaced())
                    if model.attestationFailed {
                        Button("Retry attestation") { model.retryAttestation() }
                    }
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
