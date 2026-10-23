import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct HomeView: View {
    @EnvironmentObject var store: PainStore
    @EnvironmentObject var bridge: BridgeDiscovery
    @AppStorage("openface_server_url_v3") private var openFaceServerHost = OpenFaceAnalyzer.suggestedHost
    @AppStorage("bridge_prefer_lan") private var preferLANBridge = true
    @AppStorage("facefusion_deage_enabled") private var deageEnabled = false
    @AppStorage("deage_target_age") private var deageTargetAge = 25
    @AppStorage("user_age_years") private var userAgeYears = 0
    @AppStorage("estimate_age_enabled") private var estimateAgeEnabled = true

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCamera = false
    /// Raw camera bytes held until the camera cover finishes dismissing (avoids black review cover).
    @State private var capturedRawAwaitingReview: Data?
    @State private var pendingReview: PendingReview?
    @State private var lastGoodSnapshot: LastCaptureStore.Snapshot?
    @State private var isAnalyzing = false
    @State private var analysisProgress: Double = 0
    @State private var progressLabel = "Working…"
    @State private var analysis: OpenFaceAnalysis?
    @State private var lastAgedBeforeAnalysis = false
    @State private var currentSessionID: UUID?
    @State private var currentSessionDate: Date?
    @State private var showResults = false
    @State private var errorMessage: String?

    private struct PendingReview: Identifiable {
        let id = UUID()
        let jpeg: Data
        let compare: LastCaptureStore.Snapshot?
    }

    var body: some View {
        NavigationStack {
            homeScrollContent
                .navigationTitle("painTest")
                .navigationDestination(isPresented: $showResults) {
                    resultsDestination
                }
                .overlay { analyzingOverlay }
                .alert("Couldn’t process photo", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
                .onAppear { refreshLastGood() }
                .onChange(of: selectedPhoto) { _, newItem in
                    guard let newItem else { return }
                    Task { await handlePickerItem(newItem) }
                }
                .fullScreenCover(item: $pendingReview) { item in
                    CaptureReviewView(
                        pendingJPEG: item.jpeg,
                        lastGood: item.compare,
                        onRetake: retakeFromReview,
                        onConfirm: confirmReview,
                        onCancel: cancelReview
                    )
                }
                #if canImport(UIKit) && !os(macOS)
                .fullScreenCover(isPresented: $showCamera, onDismiss: handleCameraDismissed) {
                    GuidedCameraView(
                        onCancel: {
                            capturedRawAwaitingReview = nil
                            showCamera = false
                        },
                        onCaptured: { raw in
                            capturedRawAwaitingReview = raw
                            showCamera = false
                        }
                    )
                    .ignoresSafeArea()
                }
                #endif
        }
    }

    @ViewBuilder
    private var homeScrollContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                introCard
                    .staggeredAppear(index: 0)

                openFaceAgingCard
                    .staggeredAppear(index: 1)

                takePhotoButton
                    .staggeredAppear(index: 2)

                uploadPhotoButton
                    .staggeredAppear(index: 3)

                if lastGoodSnapshot != nil {
                    lastCaptureCard
                        .staggeredAppear(index: 4)
                }

                tipsCard
                    .staggeredAppear(index: 5)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var resultsDestination: some View {
        if let analysis {
            ActionUnitsView(
                analysis: analysis,
                capturedAt: currentSessionDate,
                agedBeforeAnalysis: lastAgedBeforeAnalysis,
                sessionID: currentSessionID
            )
        }
    }

    @ViewBuilder
    private var analyzingOverlay: some View {
        if isAnalyzing {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text(progressLabel)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ProgressView(value: analysisProgress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(.indigo)

                    HStack {
                        Text(percentLabel)
                            .font(.title2.monospacedDigit().weight(.bold))
                            .contentTransition(.numericText())
                        Spacer()
                        Text("of 100%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(22)
                .frame(maxWidth: 320)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .animation(.easeInOut(duration: 0.2), value: analysisProgress)
                .animation(.easeInOut(duration: 0.2), value: progressLabel)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(progressLabel), \(percentLabel)")
        }
    }

    private var percentLabel: String {
        "\(Int((analysisProgress * 100).rounded()))%"
    }

    private func handleCameraDismissed() {
        guard let raw = capturedRawAwaitingReview else { return }
        capturedRawAwaitingReview = nil
        // Present after the camera cover is fully gone — back-to-back covers render black otherwise.
        DispatchQueue.main.async {
            presentReview(fromRawOrPrepared: raw, alreadyPreprocessed: false)
        }
    }

    private func retakeFromReview() {
        pendingReview = nil
        #if canImport(UIKit) && !os(macOS)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            showCamera = true
        }
        #else
        errorMessage = "Retake with the camera on iPhone, or upload another photo."
        #endif
    }

    private func confirmReview(_ jpeg: Data) {
        pendingReview = nil
        Task { await process(imageData: jpeg, alreadyPreprocessed: true) }
    }

    private func cancelReview() {
        pendingReview = nil
    }

    private func beginProgress(_ label: String, at value: Double = 0.05) {
        isAnalyzing = true
        progressLabel = label
        analysisProgress = value
    }

    private func setProgress(_ value: Double, label: String? = nil) {
        analysisProgress = min(max(value, 0), 1)
        if let label {
            progressLabel = label
        }
    }

    private func endProgress() {
        isAnalyzing = false
        analysisProgress = 0
        progressLabel = "Working…"
    }

    /// Eases progress toward `cap` while a long network/OpenFace call runs.
    private func runProgressTicker(from start: Double, toward cap: Double, label: String) -> Task<Void, Never> {
        setProgress(start, label: label)
        return Task { @MainActor in
            var current = start
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000)
                if Task.isCancelled { break }
                // Asymptotic crawl so it never hits 100% until work finishes.
                current = min(cap, current + (cap - current) * 0.045)
                analysisProgress = current
                if current >= cap - 0.002 { break }
            }
        }
    }

    private var openFaceAgingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Estimate age", isOn: $estimateAgeEnabled)
                .font(.headline)

            Toggle("Normalize age before OpenFace", isOn: $deageEnabled)
                .font(.headline)

            if deageEnabled {
                Stepper(value: $deageTargetAge, in: 20...40) {
                    HStack {
                        Text("Target age")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(deageTargetAge)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.indigo)
                    }
                }

                HStack {
                    Text("Your age")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(userAgeYears > 0 ? "\(userAgeYears)" : "Set in Settings")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(userAgeYears > 0 ? .indigo : .orange)
                }

                Text(
                    userAgeYears > 0
                        ? "FaceFusion de-ages from your age (\(userAgeYears)) toward \(deageTargetAge), then OpenFace measures PSPI. Faces within 6 years of the target are left alone."
                        : "Set your age in Settings so de-aging knows how many years to subtract."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text("Turn on to de-age faces to a common age before Action Unit analysis. Set your age in Settings first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .animatedCard()
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture a face photo")
                .font(.title2.bold())
            Text("Guided camera helps you frame the face, then you review before sending to OpenFace.")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            if deageEnabled {
                Text("Age normalization on → faces older than \(deageTargetAge) are de-aged, then OpenFace measures PSPI.")
                    .font(.caption)
                    .foregroundStyle(.indigo)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .animatedCard()
    }

    private var takePhotoButton: some View {
        Button {
            #if canImport(UIKit) && !os(macOS)
            refreshLastGood()
            showCamera = true
            #else
            errorMessage = "Camera capture is available on iPhone. On Mac, use Upload photo."
            #endif
        } label: {
            actionRow(
                systemImage: "camera.fill",
                title: "Take photo",
                subtitle: "Guided oval + live yaw / quality hints"
            )
        }
        .disabled(isAnalyzing)
        .pressableButtonStyle()
        .accessibilityLabel("Take photo")
    }

    private var uploadPhotoButton: some View {
        PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
            actionRow(
                systemImage: "photo.on.rectangle.angled",
                title: "Upload photo",
                subtitle: "Review before analyzing"
            )
        }
        .disabled(isAnalyzing)
        .accessibilityLabel("Upload photo")
    }

    private var lastCaptureCard: some View {
        Button {
            guard let snap = lastGoodSnapshot else { return }
            pendingReview = PendingReview(jpeg: snap.jpeg, compare: nil)
        } label: {
            HStack(spacing: 14) {
                if let snap = lastGoodSnapshot,
                   let image = PlatformImage(data: snap.jpeg) {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Last good capture")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let snap = lastGoodSnapshot {
                        HStack(spacing: 6) {
                            Text(snap.meta.date.formatted(date: .abbreviated, time: .shortened))
                            if let pspi = snap.meta.pspi {
                                Text("· PSPI \(String(format: "%.1f", pspi))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Text("Compare or re-analyze without re-uploading a new photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .animatedCard()
        }
        .buttonStyle(.plain)
        .disabled(isAnalyzing)
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("For best results")
                .font(.headline)
            Text("• Fit your face in the oval\n• Keep yaw near 0° (face straight on)\n• Wait for green “Looking good” before shutter")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .animatedCard()
    }

    private func actionRow(systemImage: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .opacity(0.92)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right.circle.fill")
                .font(.title2)
                .opacity(0.9)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.cyan, .indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .indigo.opacity(0.25), radius: 8, y: 4)
        .opacity(isAnalyzing ? 0.7 : 1)
    }

    private func refreshLastGood() {
        lastGoodSnapshot = LastCaptureStore.load()
    }

    private func presentReview(fromRawOrPrepared data: Data, alreadyPreprocessed: Bool) {
        refreshLastGood()
        let prepared: Data
        if alreadyPreprocessed {
            prepared = data
        } else {
            switch ImagePreprocessor.prepareForOpenFace(data: data) {
            case .success(let jpeg):
                prepared = jpeg
            case .failure(let failure):
                errorMessage = failure.localizedDescription
                return
            }
        }
        pendingReview = PendingReview(jpeg: prepared, compare: lastGoodSnapshot)
    }

    @MainActor
    private func handlePickerItem(_ item: PhotosPickerItem) async {
        beginProgress("Reading photo…", at: 0.1)
        defer {
            endProgress()
            selectedPhoto = nil
        }

        do {
            setProgress(0.35, label: "Preparing…")
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "Could not read the selected photo."
                return
            }
            setProgress(0.7, label: "Checking face…")
            switch ImagePreprocessor.prepareForOpenFace(data: data) {
            case .success(let jpeg):
                setProgress(1.0, label: "Ready")
                presentReview(fromRawOrPrepared: jpeg, alreadyPreprocessed: true)
            case .failure(let failure):
                errorMessage = failure.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func process(imageData: Data, alreadyPreprocessed: Bool = false) async {
        beginProgress("Preparing…", at: 0.05)
        defer { endProgress() }

        let jpeg: Data
        if alreadyPreprocessed {
            jpeg = imageData
            setProgress(0.12, label: "Photo ready")
        } else {
            setProgress(0.1, label: "Checking face…")
            switch ImagePreprocessor.prepareForOpenFace(data: imageData) {
            case .success(let prepared):
                jpeg = prepared
                setProgress(0.18, label: "Photo ready")
            case .failure(let failure):
                errorMessage = failure.localizedDescription
                return
            }
        }

        if deageEnabled, userAgeYears <= 0 {
            errorMessage = "Set your age in Settings so de-aging can aim at the target age."
            return
        }

        let waitLabel = deageEnabled
            ? "De-aging + OpenFace…"
            : (estimateAgeEnabled ? "Estimating age + OpenFace…" : "Running OpenFace…")
        let ticker = runProgressTicker(from: 0.2, toward: 0.92, label: waitLabel)
        defer { ticker.cancel() }
        do {
            let result = try await withBridgeFallback { host in
                try await OpenFaceAnalyzer.analyze(
                    imageData: jpeg,
                    serverHost: host,
                    deage: deageEnabled,
                    targetAge: deageEnabled ? deageTargetAge : nil,
                    sourceAge: deageEnabled && userAgeYears > 0 ? userAgeYears : nil,
                    estimateAge: estimateAgeEnabled
                )
            }
            ticker.cancel()
            setProgress(0.96, label: "Saving…")
            let aged = result.deageInfo?.deaged ?? deageEnabled
            lastAgedBeforeAnalysis = aged
            analysis = result
            let session = store.addSession(analysis: result, agedBeforeAnalysis: aged)
            currentSessionID = session.id
            currentSessionDate = session.date
            if result.outcome == .success {
                LastCaptureStore.save(jpeg: jpeg, analysis: result)
                refreshLastGood()
            }
            setProgress(1.0, label: "Done")
            try? await Task.sleep(nanoseconds: 180_000_000)
            showResults = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Bridge addresses to try in order: the Mac on this Wi‑Fi (if it answers a health check), then the tunnel URL.
    private func candidateHosts() async -> [String] {
        var hosts: [String] = []
        if preferLANBridge, let lan = bridge.lanURL, await OpenFaceAnalyzer.checkHealth(host: lan, timeout: 2) {
            hosts.append(lan)
        }
        let manual = openFaceServerHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty, !hosts.contains(manual) {
            hosts.append(manual)
        }
        return hosts
    }

    private func withBridgeFallback<T>(_ work: (String) async throws -> T) async throws -> T {
        let hosts = await candidateHosts()
        guard !hosts.isEmpty else { throw OpenFaceAnalyzerError.missingServerHost }
        var lastError: Error = OpenFaceAnalyzerError.missingServerHost
        for host in hosts {
            do {
                return try await work(host)
            } catch let error as OpenFaceAnalyzerError {
                guard case .serverUnreachable = error else { throw error }
                lastError = error
            }
        }
        throw lastError
    }
}

#Preview {
    HomeView()
        .environmentObject(PainStore())
        .environmentObject(BridgeDiscovery.shared)
}
