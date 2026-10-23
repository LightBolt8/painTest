import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// All analysis sessions as a CSV file, generated when the share sheet asks for it.
struct SessionCSVExport: Transferable {
    let sessions: [AnalysisSession]
    /// The user's neutral-face photo PSPI at export time, for the pspi_minus_neutral column.
    var neutralPhotoPSPI: Double? = nil
    /// Whether the neutral PSPI was measured on a de-aged face; the difference is left blank when modes differ.
    var neutralDeaged: Bool? = nil

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            SentTransferredFile(try export.writeFile())
        }
        .suggestedFileName("painTest-sessions.csv")
    }

    func writeFile() throws -> URL {
        let stamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withFullDate]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("painTest-sessions-\(stamp).csv")
        try csvString().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func csvString() -> String {
        let auCodes = Set(sessions.flatMap { $0.actionUnits.map(\.code) }).sorted()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = .current

        var header = [
            "session_id", "date", "outcome", "estimated_pspi", "self_reported_pain_0_10",
            "confidence", "yaw_deg", "pitch_deg", "roll_deg",
            "passed_strict_checks", "aged_before_analysis", "notes",
            "est_age", "est_age_spread", "est_age_low", "est_age_high",
            "deage_target_age", "deage_direction_years", "deage_passes", "deage_skipped",
            "deaged_age", "deaged_age_low", "deaged_age_high",
            "original_photo_pspi_comparison", "expression_drift", "pspi_minus_neutral",
        ]
        for code in auCodes {
            header.append("\(code)_intensity")
            header.append("\(code)_present")
        }

        var lines = [header.joined(separator: ",")]
        for session in sessions.sorted(by: { $0.date < $1.date }) {
            let byCode = Dictionary(uniqueKeysWithValues: session.actionUnits.map { ($0.code, $0) })
            var row = [
                session.id.uuidString,
                isoFormatter.string(from: session.date),
                session.faceFound ? "success" : "face_not_found",
                String(format: "%.3f", session.pspi),
                session.selfReportedPain.map(String.init) ?? "",
                String(format: "%.3f", session.confidence),
                String(format: "%.2f", session.yawDegrees),
                String(format: "%.2f", session.pitchDegrees),
                String(format: "%.2f", session.rollDegrees),
                session.passedStrictChecks ? "1" : "0",
                session.agedBeforeAnalysis ? "1" : "0",
                Self.escape(session.notes),
            ]
            let sameMode = neutralDeaged.map { $0 == (session.deageInfo?.deaged == true) } ?? true
            row += Self.ageFields(session, neutralPhotoPSPI: sameMode ? neutralPhotoPSPI : nil)
            for code in auCodes {
                if let au = byCode[code] {
                    row.append(String(format: "%.3f", au.intensity))
                    row.append(au.present ? "1" : "0")
                } else {
                    row.append("")
                    row.append("")
                }
            }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func ageFields(_ session: AnalysisSession, neutralPhotoPSPI: Double?) -> [String] {
        let age = session.ageEstimate
        let info = session.deageInfo
        let after = info?.deagedAge
        let ageColumns: [String] = [
            age.map { String(format: "%.1f", $0.estimate) } ?? "",
            age?.spread.map { String(format: "%.1f", $0) } ?? "",
            age.map { String($0.low) } ?? "",
            age.map { String($0.high) } ?? "",
        ]
        let deageColumns: [String] = [
            info?.targetAge.map { String($0) } ?? "",
            info.map { String($0.directionYears) } ?? "",
            info?.passes.map { String($0) } ?? "",
            info?.skipped?.rawValue ?? "",
            after.map { String(format: "%.1f", $0.estimate) } ?? "",
            after.map { String($0.low) } ?? "",
            after.map { String($0.high) } ?? "",
        ]
        let pspiColumns: [String] = [
            info?.originalPSPI.map { String(format: "%.3f", $0) } ?? "",
            info?.expressionDrift.map { String(format: "%.3f", $0) } ?? "",
            (session.faceFound ? neutralPhotoPSPI : nil).map { String(format: "%.3f", session.pspi - $0) } ?? "",
        ]
        return ageColumns + deageColumns + pspiColumns
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
