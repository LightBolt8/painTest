import SwiftUI

struct ActionUnitsView: View {
    let analysis: OpenFaceAnalysis
    var capturedAt: Date? = nil
    var agedBeforeAnalysis: Bool = false
    /// When set, shows the self-report section and saves edits to this session.
    var sessionID: UUID? = nil

    @ObservedObject private var baselineStore = NeutralBaselineStore.shared

    var body: some View {
        Group {
            switch analysis.outcome {
            case .faceNotFound:
                faceNotFoundContent
            case .success:
                resultsContent
            }
        }
        .navigationTitle("Action Units")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var faceNotFoundContent: some View {
        List {
            if let capturedAt {
                Section {
                    labeledValue(
                        "Captured",
                        capturedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    if agedBeforeAnalysis {
                        labeledValue("Preprocessing", "Aged before OpenFace")
                    }
                }
            }
            Section {
                ContentUnavailableView {
                    Label("Face not found", systemImage: "face.dashed")
                } description: {
                    Text(faceNotFoundReason)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            }

            if let sessionID {
                SelfReportSection(sessionID: sessionID)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var ageSection: some View {
        Section {
            if let age = analysis.ageEstimate {
                labeledValue("Estimated age", "\(age.label) yrs")
            }
            if let info = analysis.deageInfo {
                switch info.skipped {
                case .atOrBelowTarget:
                    labeledValue("Normalization", "Skipped — already ≤ \(info.targetAge.map(String.init) ?? "target")")
                case .ageUnknown:
                    labeledValue("Normalization", "Skipped — age unknown")
                case nil where info.deaged:
                    if let target = info.targetAge {
                        labeledValue("Target age", "\(target)")
                    }
                    labeledValue(
                        "De-aged by",
                        "\(abs(info.directionYears)) yrs"
                            + ((info.passes ?? 1) > 1 ? " · \(info.passes ?? 1) passes" : "")
                    )
                    if let after = info.deagedAge {
                        labeledValue("Reads as after", "\(after.label) yrs")
                    }
                    if let original = info.originalPSPI {
                        labeledValue("Original photo PSPI (comparison)", String(format: "%.1f", original))
                    }
                    if let drift = info.expressionDrift {
                        labeledValue("Expression change", String(format: "%.2f / 5", drift))
                    }
                    if info.expressionChanged(pspi: analysis.pspi) {
                        Label(
                            "De-aging changed the pain-related Action Units noticeably compared with the original photo.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                case nil:
                    labeledValue("Normalization", "Not applied")
                }
            }
        } header: {
            Text("Age")
        } footer: {
            Text(ageFooter)
        }
    }

    private var ageFooter: String {
        var text = "Age is FairFace's estimate from FaceFusion"
        if let age = analysis.ageEstimate {
            text += " (most likely band \(age.bandLabel))"
        }
        text += ". When de-aging runs, PSPI above is OpenFace on the de-aged face; OpenFace's score on the original photo is listed here for comparison."
        return text
    }

    @ViewBuilder
    private var neutralBaselineSection: some View {
        Section {
            if let delta = baselineStore.delta(for: analysis), let base = baselineStore.baseline,
               base.sessionID != sessionID {
                labeledValue("Change vs neutral", signed(delta))
                labeledValue(
                    "Neutral from",
                    base.date.formatted(date: .abbreviated, time: .omitted)
                        + String(format: " · PSPI %.1f", base.photoPSPI)
                )
            } else if baselineStore.baseline?.sessionID == sessionID {
                Label("This capture is your neutral baseline", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if baselineStore.baseline != nil, !baselineStore.isComparable(analysis) {
                Text(
                    baselineStore.baseline?.deaged == true
                        ? "Your neutral face was age-normalized and this capture wasn't, so they can't be compared."
                        : "This capture was age-normalized and your neutral face wasn't, so they can't be compared."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let sessionID, let capturedAt, baselineStore.baseline?.sessionID != sessionID {
                Button {
                    baselineStore.setBaseline(sessionID: sessionID, date: capturedAt, analysis: analysis)
                } label: {
                    Label(
                        baselineStore.baseline == nil ? "Use as my neutral face" : "Replace neutral face with this",
                        systemImage: "face.smiling"
                    )
                }
            }
        } header: {
            Text("Your neutral face")
        } footer: {
            Text("Take one capture with a relaxed, no-pain face and set it as neutral. Later captures show the change from it, which cancels out your age, wrinkles, and resting expression without any de-aging.")
        }
    }

    private func signed(_ value: Double) -> String {
        String(format: "%@%.1f", value >= 0 ? "+" : "−", abs(value))
    }

    private var faceNotFoundReason: String {
        if analysis.confidence < 0.01 {
            return "OpenFace didn’t lock onto a face. Hold the phone straight, face the camera, and fill more of the frame."
        }
        var reasons: [String] = []
        if analysis.confidence < OpenFaceAnalysis.confidenceThreshold {
            reasons.append(
                String(
                    format: "confidence %.0f%% (need ≥ %.0f%%)",
                    analysis.confidence * 100,
                    OpenFaceAnalysis.confidenceThreshold * 100
                )
            )
        }
        if abs(analysis.yawDegrees) > OpenFaceAnalysis.maxAbsYawDegrees {
            reasons.append(
                String(
                    format: "yaw %.0f° (need ≤ %.0f°)",
                    abs(analysis.yawDegrees),
                    OpenFaceAnalysis.maxAbsYawDegrees
                )
            )
        }
        if reasons.isEmpty {
            return "OpenFace could not reliably detect a face in this photo."
        }
        return reasons.joined(separator: " · ")
    }

    private var resultsContent: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    if let data = analysis.sourceImageData,
                       let image = PlatformImage(data: data) {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if let capturedAt {
                            labeledValue(
                                "Captured",
                                capturedAt.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                        labeledValue("Confidence", String(format: "%.0f%%", analysis.confidence * 100))
                        labeledValue("Yaw", String(format: "%.1f°", analysis.yawDegrees))
                        labeledValue("Pitch", String(format: "%.1f°", analysis.pitchDegrees))
                        if agedBeforeAnalysis {
                            labeledValue("Preprocessing", "Aged before OpenFace")
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if !analysis.passesStrictChecks {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Low-confidence capture")
                                .font(.subheadline.weight(.semibold))
                            Text(lowConfidenceReason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let sessionID {
                SelfReportSection(sessionID: sessionID)
            }

            Section {
                pspiHeader
                pspiComponentRow("AU4 · Brow lowerer", analysis.pspiComponents.au4, max: 5)
                pspiComponentRow("max(AU6, AU7) · Orbital", analysis.pspiComponents.orbital, max: 5)
                pspiComponentRow("max(AU9, AU10) · Levator", analysis.pspiComponents.levator, max: 5)
                pspiComponentRow(
                    analysis.pspiComponents.usedAU45Proxy
                        ? "AU45 proxy · Eye closure"
                        : "AU43 · Eyes closed",
                    analysis.pspiComponents.eyeClosure,
                    max: 1
                )
            } header: {
                Text("Estimated PSPI")
            } footer: {
                Text(
                    "An estimate of the Prkachin & Solomon Pain Intensity scale (0–16): AU4 + max(AU6,AU7) + max(AU9,AU10) + eye closure. "
                        + "Real PSPI is scored by trained FACS coders; OpenFace intensities aren’t calibrated to that, so treat this as a relative signal, not a clinical score."
                        + (analysis.pspiComponents.usedAU45Proxy
                            ? " Eye closure uses AU45 (blink) because OpenFace doesn’t report AU43."
                            : "")
                )
            }

            if sessionID != nil || baselineStore.baseline != nil {
                neutralBaselineSection
            }

            if analysis.ageEstimate != nil || analysis.deageInfo != nil {
                ageSection
            }

            Section {
                ForEach(analysis.actionUnits) { au in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(au.code)
                                .font(.subheadline.weight(.semibold))
                            Text(au.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.2f", au.intensity))
                            .font(.body.monospacedDigit().weight(.semibold))
                            .foregroundStyle(au.present ? Color.primary : Color.secondary)
                        Text(au.present ? "on" : "off")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(au.present ? Color.indigo : Color.secondary)
                            .frame(width: 28, alignment: .trailing)
                    }
                    .opacity(au.present ? 1 : 0.55)
                    .staggeredAppear(index: min(analysis.actionUnits.firstIndex(of: au) ?? 0, 12))
                }
            } header: {
                Text("Action units")
            } footer: {
                Text("Intensity is OpenFace’s 0–5 estimate. “On” means occurrence ≥ 0.5 or intensity ≥ 1. Active units are listed first.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var pspiHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Score")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.1f", analysis.pspi))
                .font(.largeTitle.bold().monospacedDigit())
                .foregroundStyle(.indigo)
                .contentTransition(.numericText())
            Text("/ 16")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Estimated PSPI \(String(format: "%.1f", analysis.pspi)) out of 16")
    }

    private var lowConfidenceReason: String {
        var reasons: [String] = []
        if analysis.confidence < OpenFaceAnalysis.strictConfidenceThreshold {
            reasons.append(String(
                format: "confidence %.0f%% (research needs ≥ %.0f%%)",
                analysis.confidence * 100,
                OpenFaceAnalysis.strictConfidenceThreshold * 100
            ))
        }
        if abs(analysis.yawDegrees) > OpenFaceAnalysis.strictMaxAbsYawDegrees {
            reasons.append(String(
                format: "head turned %.0f° (research needs ≤ %.0f°)",
                abs(analysis.yawDegrees),
                OpenFaceAnalysis.strictMaxAbsYawDegrees
            ))
        }
        let detail = reasons.isEmpty ? "Outside research thresholds" : reasons.joined(separator: " · ").capitalizedFirst
        return detail + ". Hidden from Trends unless you include low-confidence captures."
    }

    private func pspiComponentRow(_ title: String, _ value: Double, max: Double) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(String(format: "%.1f / %.0f", value, max))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func labeledValue(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.subheadline)
    }
}

/// Self-reported pain (0–10) and free-text notes, saved to the session as they change.
struct SelfReportSection: View {
    @EnvironmentObject var store: PainStore
    let sessionID: UUID

    @State private var pain: Int?
    @State private var notes = ""
    @State private var loaded = false
    @FocusState private var notesFocused: Bool

    var body: some View {
        Section {
            if let pain {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("How much pain do you feel?")
                            .font(.subheadline)
                        Spacer()
                        Text("\(pain) / 10")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.indigo)
                            .contentTransition(.numericText())
                    }
                    Slider(
                        value: Binding(
                            get: { Double(pain) },
                            set: { self.pain = Int($0.rounded()) }
                        ),
                        in: 0...10,
                        step: 1
                    )
                    HStack {
                        Text("No pain")
                        Spacer()
                        Text("Worst imaginable")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Button("Remove rating", role: .destructive) {
                    self.pain = nil
                }
                .font(.subheadline)
            } else {
                Button {
                    pain = 0
                } label: {
                    Label("Add your pain rating (0–10)", systemImage: "hand.point.up.left")
                }
            }

            TextField("Notes (meds, activity, time of day…)", text: $notes, axis: .vertical)
                .lineLimit(2...5)
                .focused($notesFocused)
        } header: {
            Text("Your report")
        } footer: {
            Text("Compare how you feel with the estimated PSPI. Included in CSV export.")
        }
        .onAppear(perform: loadIfNeeded)
        .onChange(of: pain) { _, _ in save() }
        .onChange(of: notesFocused) { _, focused in
            if !focused { save() }
        }
        .onDisappear(perform: save)
    }

    private func loadIfNeeded() {
        guard !loaded, let session = store.session(withID: sessionID) else { return }
        pain = session.selfReportedPain
        notes = session.notes
        loaded = true
    }

    private func save() {
        guard loaded else { return }
        store.updateSelfReport(
            sessionID: sessionID,
            pain: pain,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}
#endif

#Preview("Success") {
    NavigationStack {
        ActionUnitsView(
            analysis: OpenFaceAnalysis(
                outcome: .success,
                confidence: 0.93,
                yawDegrees: -0.6,
                pitchDegrees: 12,
                rollDegrees: -5,
                actionUnits: [
                    ActionUnitValue(code: "AU04", name: "Brow Lowerer", intensity: 2.4, present: true),
                    ActionUnitValue(code: "AU06", name: "Cheek Raiser", intensity: 1.5, present: true),
                    ActionUnitValue(code: "AU07", name: "Lid Tightener", intensity: 0.8, present: true),
                    ActionUnitValue(code: "AU09", name: "Nose Wrinkler", intensity: 1.2, present: true),
                    ActionUnitValue(code: "AU45", name: "Blink", intensity: 0.0, present: true)
                ],
                sourceImageData: nil
            ),
            capturedAt: Date(),
            agedBeforeAnalysis: false
        )
    }
}

#Preview("Face not found") {
    NavigationStack {
        ActionUnitsView(
            analysis: OpenFaceAnalysis(
                outcome: .faceNotFound,
                confidence: 0.4,
                yawDegrees: 42,
                pitchDegrees: 0,
                rollDegrees: 0,
                actionUnits: [],
                sourceImageData: nil
            )
        )
    }
}
