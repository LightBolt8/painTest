import Foundation

struct ActionUnitValue: Identifiable, Hashable, Codable {
    var id: String { code }
    let code: String
    let name: String
    let intensity: Double
    let present: Bool
}

/// Apparent age from FaceFusion's fairface classifier.
struct AgeEstimate: Hashable, Codable {
    /// Most likely decade band; `high` is inclusive, so 30–39 is low 30, high 39.
    let low: Int
    let high: Int
    /// Expected age over all band probabilities (older sessions stored the band midpoint).
    let estimate: Double
    /// Spread of the band probabilities in years; nil for sessions saved before it existed.
    var spread: Double? = nil

    var bandLabel: String {
        high >= 100 ? "\(low)+" : "\(low)–\(high)"
    }

    var label: String {
        guard let spread else { return bandLabel }
        return String(format: "≈ %.0f ± %.0f", estimate, spread)
    }
}

/// What the bridge did about age normalization for one capture.
struct DeageInfo: Hashable, Codable {
    enum SkipReason: String, Codable {
        case atOrBelowTarget = "at_or_below_target"
        case ageUnknown = "age_unknown"
    }

    let deaged: Bool
    let targetAge: Int?
    /// Years FRAN was asked to move the face (negative = younger).
    let directionYears: Int
    let skipped: SkipReason?
    /// Apparent age of the de-aged photo, to check how close FRAN got to the target.
    let deagedAge: AgeEstimate?
    /// PSPI from OpenFace on the original, un-aged photo. A comparison only — when de-aged, the
    /// session's PSPI comes from OpenFace on the de-aged image.
    var originalPSPI: Double? = nil
    /// Only in sessions saved while the original photo drove the analysis; used to migrate them.
    var deagedPSPI: Double? = nil
    /// FaceFusion passes run; the bridge re-checks age and runs a second pass if the first fell short.
    var passes: Int? = nil
    /// Mean absolute change (0–5) in the PSPI Action Units between the original and de-aged photo.
    var expressionDrift: Double? = nil

    static let driftWarningThreshold = 0.5
    static let pspiGapWarningThreshold = 1.5

    /// De-aging altered the pain-related Action Units noticeably compared with the original photo.
    func expressionChanged(pspi: Double) -> Bool {
        if let expressionDrift, expressionDrift >= Self.driftWarningThreshold { return true }
        if let originalPSPI, abs(originalPSPI - pspi) >= Self.pspiGapWarningThreshold { return true }
        return false
    }
}

struct OpenFaceAnalysis: Hashable {
    enum Outcome: Hashable, Codable {
        case faceNotFound
        case success
    }

    let outcome: Outcome
    let confidence: Double
    let yawDegrees: Double
    let pitchDegrees: Double
    let rollDegrees: Double
    let actionUnits: [ActionUnitValue]
    let sourceImageData: Data?
    var ageEstimate: AgeEstimate? = nil
    var deageInfo: DeageInfo? = nil

    static let confidenceThreshold = 0.4
    static let maxAbsYawDegrees = 45.0

    /// Research-grade gates. Captures that pass the loose gates above but fail these are flagged low confidence.
    static let strictConfidenceThreshold = 0.7
    static let strictMaxAbsYawDegrees = 30.0

    var passesStrictChecks: Bool {
        outcome == .success
            && confidence >= Self.strictConfidenceThreshold
            && abs(yawDegrees) <= Self.strictMaxAbsYawDegrees
    }

    /// Prkachin & Solomon Pain Intensity (0–16).
    /// AU43 (eyes closed) is approximated from AU45 (blink) when AU43 is absent.
    var pspi: Double {
        PSPI.score(from: actionUnits)
    }

    var pspiComponents: PSPI.Components {
        PSPI.components(from: actionUnits)
    }

    static func fromCSVRow(
        _ values: [String: String],
        imageData: Data?
    ) -> OpenFaceAnalysis {
        let confidence = Self.double(values["confidence"]) ?? 0
        let yawRad = Self.double(values["pose_Ry"]) ?? 0
        let pitchRad = Self.double(values["pose_Rx"]) ?? 0
        let rollRad = Self.double(values["pose_Rz"]) ?? 0
        let yawDegrees = yawRad * 180 / .pi
        let pitchDegrees = pitchRad * 180 / .pi
        let rollDegrees = rollRad * 180 / .pi
        let successFlag = Self.double(values["success"]).map { $0 >= 0.5 } ?? false

        let aus = Self.parseActionUnits(values)
        let faceOK =
            successFlag
            && confidence >= confidenceThreshold
            && abs(yawDegrees) <= maxAbsYawDegrees

        return OpenFaceAnalysis(
            outcome: faceOK ? .success : .faceNotFound,
            confidence: confidence,
            yawDegrees: yawDegrees,
            pitchDegrees: pitchDegrees,
            rollDegrees: rollDegrees,
            actionUnits: aus,
            sourceImageData: imageData
        )
    }

    private static func parseActionUnits(_ values: [String: String]) -> [ActionUnitValue] {
        var codes = Set<String>()
        for key in values.keys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("AU") else { continue }
            if trimmed.hasSuffix("_r") || trimmed.hasSuffix("_c") {
                codes.insert(String(trimmed.dropLast(2)))
            }
        }

        let aus = codes.compactMap { code -> ActionUnitValue? in
            let intensity = double(values["\(code)_r"]) ?? double(values[" \(code)_r"]) ?? 0
            let occurrence = double(values["\(code)_c"]) ?? double(values[" \(code)_c"]) ?? 0
            let present = occurrence >= 0.5 || intensity >= 1.0
            return ActionUnitValue(
                code: code,
                name: ActionUnitNames.name(for: code),
                intensity: intensity,
                present: present
            )
        }

        return aus.sorted { lhs, rhs in
            if lhs.present != rhs.present { return lhs.present && !rhs.present }
            if lhs.intensity != rhs.intensity { return lhs.intensity > rhs.intensity }
            return lhs.code < rhs.code
        }
    }

    private static func double(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum PSPI {
    struct Components: Hashable {
        let au4: Double
        let orbital: Double
        let levator: Double
        let eyeClosure: Double
        let usedAU45Proxy: Bool

        var total: Double { au4 + orbital + levator + eyeClosure }
    }

    static func intensity(_ code: String, in aus: [ActionUnitValue]) -> Double {
        let value = aus.first { $0.code == code }?.intensity ?? 0
        return min(max(value, 0), 5)
    }

    static func components(from aus: [ActionUnitValue]) -> Components {
        let au4 = intensity("AU04", in: aus)
        let orbital = max(intensity("AU06", in: aus), intensity("AU07", in: aus))
        let levator = max(intensity("AU09", in: aus), intensity("AU10", in: aus))

        let hasAU43 = aus.contains { $0.code == "AU43" }
        let eyeClosure: Double
        let usedProxy: Bool
        if hasAU43 {
            let au43 = aus.first { $0.code == "AU43" }!
            eyeClosure = (au43.present || au43.intensity >= 0.5) ? 1 : 0
            usedProxy = false
        } else {
            let au45 = aus.first { $0.code == "AU45" }
            eyeClosure = (au45?.present == true || (au45?.intensity ?? 0) >= 1.0) ? 1 : 0
            usedProxy = true
        }

        return Components(
            au4: au4,
            orbital: orbital,
            levator: levator,
            eyeClosure: eyeClosure,
            usedAU45Proxy: usedProxy
        )
    }

    static func score(from aus: [ActionUnitValue]) -> Double {
        components(from: aus).total
    }
}

enum ActionUnitNames {
    static func name(for code: String) -> String {
        switch code {
        case "AU01": return "Inner Brow Raiser"
        case "AU02": return "Outer Brow Raiser"
        case "AU04": return "Brow Lowerer"
        case "AU05": return "Upper Lid Raiser"
        case "AU06": return "Cheek Raiser"
        case "AU07": return "Lid Tightener"
        case "AU09": return "Nose Wrinkler"
        case "AU10": return "Upper Lip Raiser"
        case "AU12": return "Lip Corner Puller"
        case "AU14": return "Dimpler"
        case "AU15": return "Lip Corner Depressor"
        case "AU17": return "Chin Raiser"
        case "AU20": return "Lip Stretcher"
        case "AU23": return "Lip Tightener"
        case "AU25": return "Lips Part"
        case "AU26": return "Jaw Drop"
        case "AU28": return "Lip Suck"
        case "AU43": return "Eyes Closed"
        case "AU45": return "Blink"
        default: return code
        }
    }
}
