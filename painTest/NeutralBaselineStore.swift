import Combine
import Foundation

/// The user's own relaxed, no-pain face, so later captures can be read as a change from it
/// instead of an absolute score that mixes in age, wrinkles, and resting expression.
@MainActor
final class NeutralBaselineStore: ObservableObject {
    struct Baseline: Codable, Hashable {
        let sessionID: UUID
        let date: Date
        /// OpenFace PSPI of the neutral capture.
        let photoPSPI: Double
        /// Whether that PSPI was measured on a de-aged face; nil for baselines saved before this was tracked.
        var deaged: Bool? = nil
    }

    static let shared = NeutralBaselineStore()
    private static let storageKey = "neutral_baseline_v1"

    @Published private(set) var baseline: Baseline?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey) {
            baseline = try? JSONDecoder().decode(Baseline.self, from: data)
        }
    }

    func setBaseline(sessionID: UUID, date: Date, analysis: OpenFaceAnalysis) {
        let value = Baseline(
            sessionID: sessionID,
            date: date,
            photoPSPI: analysis.pspi,
            deaged: analysis.deageInfo?.deaged == true
        )
        baseline = value
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    func clear() {
        baseline = nil
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    /// Difference between two OpenFace PSPI scores: this capture minus the neutral one.
    /// Nil when one was measured on a de-aged face and the other wasn't.
    func delta(for analysis: OpenFaceAnalysis) -> Double? {
        guard let baseline, analysis.outcome == .success, isComparable(analysis) else { return nil }
        return analysis.pspi - baseline.photoPSPI
    }

    func isComparable(_ analysis: OpenFaceAnalysis) -> Bool {
        guard let baselineDeaged = baseline?.deaged else { return true }
        return baselineDeaged == (analysis.deageInfo?.deaged == true)
    }
}
