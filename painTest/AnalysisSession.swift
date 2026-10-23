import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Saved OpenFace capture for Log → History. Thumbnails live in `SessionFileStore`, not in this struct.
struct AnalysisSession: Identifiable, Codable, Equatable {
    let id: UUID
    var date: Date
    var outcomeRaw: String
    var pspi: Double
    var confidence: Double
    var yawDegrees: Double
    var pitchDegrees: Double
    var rollDegrees: Double
    var actionUnits: [ActionUnitValue]
    var agedBeforeAnalysis: Bool
    var passedStrictChecks: Bool
    var selfReportedPain: Int?
    var notes: String
    var ageEstimate: AgeEstimate?
    var deageInfo: DeageInfo?

    /// Only set when decoding sessions saved before file storage (thumbnail was inline in UserDefaults).
    private(set) var legacyThumbnailJPEG: Data?

    var outcome: OpenFaceAnalysis.Outcome {
        outcomeRaw == "success" ? .success : .faceNotFound
    }

    var faceFound: Bool { outcome == .success }

    var thumbnailJPEG: Data? {
        SessionFileStore.thumbnail(for: id)
    }

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        analysis: OpenFaceAnalysis,
        agedBeforeAnalysis: Bool
    ) {
        self.id = id
        self.date = date
        self.outcomeRaw = analysis.outcome == .success ? "success" : "faceNotFound"
        self.pspi = analysis.pspi
        self.confidence = analysis.confidence
        self.yawDegrees = analysis.yawDegrees
        self.pitchDegrees = analysis.pitchDegrees
        self.rollDegrees = analysis.rollDegrees
        self.actionUnits = analysis.actionUnits
        self.agedBeforeAnalysis = agedBeforeAnalysis
        self.passedStrictChecks = analysis.passesStrictChecks
        self.selfReportedPain = nil
        self.notes = ""
        self.ageEstimate = analysis.ageEstimate
        self.deageInfo = analysis.deageInfo
        self.legacyThumbnailJPEG = nil
    }

    func asAnalysis() -> OpenFaceAnalysis {
        OpenFaceAnalysis(
            outcome: outcome,
            confidence: confidence,
            yawDegrees: yawDegrees,
            pitchDegrees: pitchDegrees,
            rollDegrees: rollDegrees,
            actionUnits: actionUnits,
            sourceImageData: thumbnailJPEG,
            ageEstimate: ageEstimate,
            deageInfo: deageInfo
        )
    }

    mutating func clearLegacyThumbnail() {
        legacyThumbnailJPEG = nil
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, date, outcomeRaw, pspi, confidence, yawDegrees, pitchDegrees, rollDegrees
        case actionUnits, agedBeforeAnalysis, passedStrictChecks, selfReportedPain, notes
        case ageEstimate, deageInfo
        case thumbnailJPEG
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        outcomeRaw = try c.decode(String.self, forKey: .outcomeRaw)
        pspi = try c.decode(Double.self, forKey: .pspi)
        confidence = try c.decode(Double.self, forKey: .confidence)
        yawDegrees = try c.decode(Double.self, forKey: .yawDegrees)
        pitchDegrees = try c.decode(Double.self, forKey: .pitchDegrees)
        rollDegrees = try c.decode(Double.self, forKey: .rollDegrees)
        actionUnits = try c.decode([ActionUnitValue].self, forKey: .actionUnits)
        agedBeforeAnalysis = try c.decodeIfPresent(Bool.self, forKey: .agedBeforeAnalysis) ?? false
        selfReportedPain = try c.decodeIfPresent(Int.self, forKey: .selfReportedPain)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        ageEstimate = try c.decodeIfPresent(AgeEstimate.self, forKey: .ageEstimate)
        deageInfo = try c.decodeIfPresent(DeageInfo.self, forKey: .deageInfo)
        legacyThumbnailJPEG = try c.decodeIfPresent(Data.self, forKey: .thumbnailJPEG)

        // Sessions saved while the original photo drove the analysis: PSPI comes from the de-aged image.
        if var info = deageInfo, info.deaged, let deaged = info.deagedPSPI {
            info.originalPSPI = pspi
            info.deagedPSPI = nil
            deageInfo = info
            pspi = deaged
            agedBeforeAnalysis = true
        }

        if let strict = try c.decodeIfPresent(Bool.self, forKey: .passedStrictChecks) {
            passedStrictChecks = strict
        } else {
            passedStrictChecks = outcomeRaw == "success"
                && confidence >= OpenFaceAnalysis.strictConfidenceThreshold
                && abs(yawDegrees) <= OpenFaceAnalysis.strictMaxAbsYawDegrees
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(outcomeRaw, forKey: .outcomeRaw)
        try c.encode(pspi, forKey: .pspi)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(yawDegrees, forKey: .yawDegrees)
        try c.encode(pitchDegrees, forKey: .pitchDegrees)
        try c.encode(rollDegrees, forKey: .rollDegrees)
        try c.encode(actionUnits, forKey: .actionUnits)
        try c.encode(agedBeforeAnalysis, forKey: .agedBeforeAnalysis)
        try c.encode(passedStrictChecks, forKey: .passedStrictChecks)
        try c.encodeIfPresent(selfReportedPain, forKey: .selfReportedPain)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(ageEstimate, forKey: .ageEstimate)
        try c.encodeIfPresent(deageInfo, forKey: .deageInfo)
    }

    // MARK: - Thumbnail

    static func makeThumbnail(from data: Data?) -> Data? {
        guard let data else { return nil }
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return data }
        let maxSide: CGFloat = 360
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return scaled.jpegData(compressionQuality: 0.7) ?? data
        #else
        return data
        #endif
    }
}
