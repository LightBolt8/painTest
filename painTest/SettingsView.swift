import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: PainStore
    @EnvironmentObject var bridge: BridgeDiscovery
    @AppStorage("openface_server_url_v3") private var openFaceServerHost = OpenFaceAnalyzer.suggestedHost
    @AppStorage("bridge_prefer_lan") private var preferLANBridge = true
    @AppStorage("facefusion_deage_enabled") private var deageEnabled = false
    @AppStorage("deage_target_age") private var deageTargetAge = 25
    @AppStorage("user_age_years") private var userAgeYears = 0
    @AppStorage("estimate_age_enabled") private var estimateAgeEnabled = true
    @State private var showingClearAlert = false
    @State private var showingConsent = false
    @State private var testState: ConnectionTestState = .idle

    private enum ConnectionTestState: Equatable {
        case idle
        case testing
        case done(lan: Bool?, tunnel: Bool?)
    }

    var body: some View {
        NavigationStack {
            Form {
                bridgeSection
                tunnelSection
                faceFusionSection

                Section {
                    Text("Face photos are analyzed with OpenFace on your Mac. PSPI scores are estimates, not a diagnosis.")
                        .font(.footnote)
                    Button("Review consent & privacy") {
                        showingConsent = true
                    }
                } header: {
                    Text("About painTest")
                }

                Section {
                    LabeledContent("Saved captures", value: "\(store.sessions.count)")
                    Button("Delete all data", role: .destructive) {
                        showingClearAlert = true
                    }
                    .disabled(store.sessions.isEmpty && store.entries.isEmpty && !LastCaptureStore.hasLastGood)
                } header: {
                    Text("Data")
                } footer: {
                    Text("Removes every capture, thumbnail, note, self-report, and the saved last capture from this device.")
                }
            }
            .navigationTitle("Settings")
            .alert("Delete all data?", isPresented: $showingClearAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    store.clearAll()
                }
            } message: {
                Text("This permanently removes every capture, photo thumbnail, and note stored on this device.")
            }
            .sheet(isPresented: $showingConsent) {
                ConsentView(isReview: true) {
                    showingConsent = false
                }
            }
        }
    }

    private var bridgeSection: some View {
        Section {
            Toggle("Use Mac on same Wi‑Fi", isOn: $preferLANBridge)

            HStack(spacing: 10) {
                Image(systemName: bridge.lanURL != nil ? "checkmark.circle.fill" : "wifi")
                    .foregroundStyle(bridge.lanURL != nil ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    if let url = bridge.lanURL {
                        Text("Found \(bridge.serviceName ?? "Mac bridge")")
                            .font(.subheadline.weight(.semibold))
                        Text(url)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(bridge.isBrowsing ? "Searching this Wi‑Fi…" : "Not searching")
                            .font(.subheadline)
                        Text("Start the bridge on your Mac to appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                Task { await runConnectionTest() }
            } label: {
                HStack {
                    Text("Test connection")
                    Spacer()
                    if testState == .testing {
                        ProgressView()
                    }
                }
            }
            .disabled(testState == .testing)

            if case let .done(lan, tunnel) = testState {
                if let lan {
                    testResultRow("Same Wi‑Fi", ok: lan)
                }
                if let tunnel {
                    testResultRow("Tunnel URL", ok: tunnel)
                }
                if lan == nil && tunnel == nil {
                    Text("No bridge address to test. Join your Mac’s Wi‑Fi or paste a tunnel URL below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("OpenFace bridge")
        } footer: {
            Text("At home the app finds your Mac automatically. Away from home it falls back to the tunnel URL below.")
        }
    }

    private var tunnelSection: some View {
        Section {
            TextField("https://openface.example.com", text: $openFaceServerHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #if canImport(UIKit)
                .keyboardType(.URL)
                .textContentType(.URL)
                #endif
            Button("Use last quick-tunnel URL") {
                openFaceServerHost = OpenFaceAnalyzer.suggestedHost
            }
        } header: {
            Text("Tunnel URL (away from home)")
        } footer: {
            Text("Quick tunnels (trycloudflare.com) change every restart. Run scripts/openface_stable.sh with a named tunnel for a URL that never changes.")
        }
    }

    private var faceFusionSection: some View {
        Section {
            Stepper(value: $userAgeYears, in: 0...99) {
                HStack {
                    Text("Your age")
                    Spacer()
                    Text(userAgeYears > 0 ? "\(userAgeYears)" : "Not set")
                        .monospacedDigit()
                        .foregroundStyle(userAgeYears > 0 ? Color.secondary : Color.orange)
                }
            }
            Toggle("Estimate age from photo", isOn: $estimateAgeEnabled)
            Toggle("Normalize age before OpenFace", isOn: $deageEnabled)
            Stepper(value: $deageTargetAge, in: 20...40) {
                HStack {
                    Text("Target age")
                    Spacer()
                    Text("\(deageTargetAge)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!deageEnabled)
            Text("Your age is how many years FaceFusion subtracts to reach the target (for example 54 → 25 is 29 years younger). The old “Age look” slider is gone — that was only a preview with no OpenFace score.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("FaceFusion")
        }
    }

    private func testResultRow(_ title: String, ok: Bool) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(ok ? "Reachable" : "Not reachable")
                    .foregroundStyle(ok ? .green : .red)
            }
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
        }
        .font(.subheadline)
    }

    @MainActor
    private func runConnectionTest() async {
        testState = .testing
        let lanHost = bridge.lanURL
        let tunnelHost = openFaceServerHost.trimmingCharacters(in: .whitespacesAndNewlines)

        async let lanResult: Bool? = {
            guard let lanHost else { return nil }
            return await OpenFaceAnalyzer.checkHealth(host: lanHost)
        }()
        async let tunnelResult: Bool? = {
            guard !tunnelHost.isEmpty else { return nil }
            return await OpenFaceAnalyzer.checkHealth(host: tunnelHost, timeout: 8)
        }()

        testState = .done(lan: await lanResult, tunnel: await tunnelResult)
    }
}

#Preview {
    SettingsView()
        .environmentObject(PainStore())
        .environmentObject(BridgeDiscovery.shared)
}
