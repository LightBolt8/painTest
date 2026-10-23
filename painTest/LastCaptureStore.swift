import Foundation

/// Persists the last successful Action Units capture JPEG for retake/compare.
enum LastCaptureStore {
    private static let jpegName = "last_good_capture.jpg"
    private static let metaName = "last_good_capture.json"

    struct Meta: Codable {
        var date: Date
        var pspi: Double?
        var confidence: Double?
        var yawDegrees: Double?
    }

    struct Snapshot {
        let jpeg: Data
        let meta: Meta
    }

    private static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
    }

    private static var jpegURL: URL { directory.appendingPathComponent(jpegName) }
    private static var metaURL: URL { directory.appendingPathComponent(metaName) }

    static var hasLastGood: Bool {
        FileManager.default.fileExists(atPath: jpegURL.path)
    }

    static func load() -> Snapshot? {
        guard let jpeg = try? Data(contentsOf: jpegURL) else { return nil }
        let meta: Meta
        if let data = try? Data(contentsOf: metaURL),
           let decoded = try? JSONDecoder().decode(Meta.self, from: data) {
            meta = decoded
        } else {
            meta = Meta(date: Date(), pspi: nil, confidence: nil, yawDegrees: nil)
        }
        return Snapshot(jpeg: jpeg, meta: meta)
    }

    static func save(jpeg: Data, analysis: OpenFaceAnalysis) {
        guard analysis.outcome == .success else { return }
        let meta = Meta(
            date: Date(),
            pspi: analysis.pspi,
            confidence: analysis.confidence,
            yawDegrees: analysis.yawDegrees
        )
        try? jpeg.write(to: jpegURL, options: .atomic)
        if let encoded = try? JSONEncoder().encode(meta) {
            try? encoded.write(to: metaURL, options: .atomic)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: jpegURL)
        try? FileManager.default.removeItem(at: metaURL)
    }
}
