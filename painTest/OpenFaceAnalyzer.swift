import Foundation

enum OpenFaceAnalyzerError: LocalizedError {
    case binaryMissing(String)
    case failedToWriteImage
    case processFailed(String)
    case csvMissing
    case csvEmpty
    case serverUnreachable(String)
    case missingServerHost

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let path):
            return "OpenFace not found at \(path)."
        case .failedToWriteImage:
            return "Could not save the selected photo for analysis."
        case .processFailed(let message):
            return message
        case .csvMissing:
            return "OpenFace did not produce an output file."
        case .csvEmpty:
            return "OpenFace returned no face measurements."
        case .serverUnreachable(let detail):
            return "Couldn’t reach the OpenFace bridge (\(detail)). Make sure the bridge is running on your Mac. On the same Wi‑Fi it’s found automatically; away from home, paste the tunnel URL into Settings."
        case .missingServerHost:
            return "No OpenFace bridge found. Join the same Wi‑Fi as your Mac, or paste the tunnel URL in Settings."
        }
    }
}

enum OpenFaceAnalyzer {
    private static let defaultPort = 8765
    /// Current Cloudflare quick tunnel (no same-Wi‑Fi needed). Re-run openface_phone.py if this expires.
    static let suggestedHost = "https://lucas-uniprotkb-saving-choose.trycloudflare.com"

    private static var featureExtractionURL: URL {
        openFaceBinDirectory.appendingPathComponent("FeatureExtraction")
    }

    private static var openFaceBinDirectory: URL {
        defaultOpenFaceRoot().appendingPathComponent("build/bin", isDirectory: true)
    }

    /// - Parameters:
    ///   - targetAge: When de-aging, make the face look about this old.
    ///   - sourceAge: The person's real age from Settings. Direction is target − source.
    ///   - estimateAge: Ask the bridge for the apparent age band of the photo (display only).
    static func analyze(
        imageData: Data,
        serverHost: String,
        deage: Bool = false,
        deageDirection: Int = -60,
        targetAge: Int? = nil,
        sourceAge: Int? = nil,
        estimateAge: Bool = false
    ) async throws -> OpenFaceAnalysis {
        #if os(macOS)
        // The local FeatureExtraction process can't estimate age or target an age; only the bridge can.
        if !estimateAge && targetAge == nil && sourceAge == nil {
            if let analysis = try? analyzeWithProcess(
                imageData: imageData,
                deage: deage,
                deageDirection: deageDirection
            ) {
                return analysis
            }
        }
        #endif
        return try await analyzeWithLocalServer(
            imageData: imageData,
            serverHost: serverHost,
            deage: deage,
            deageDirection: deageDirection,
            targetAge: targetAge,
            sourceAge: sourceAge,
            estimateAge: estimateAge
        )
    }

    #if os(macOS)
    private static func analyzeWithProcess(
        imageData: Data,
        deage: Bool,
        deageDirection: Int
    ) throws -> OpenFaceAnalysis {
        let binary = featureExtractionURL
        let binDir = openFaceBinDirectory
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw OpenFaceAnalyzerError.binaryMissing(binary.path)
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("painTest-openface-\(UUID().uuidString)", isDirectory: true)
        let outDir = workDir.appendingPathComponent("out", isDirectory: true)
        let imageURL = workDir.appendingPathComponent("input.jpg")

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var workingImage = imageData
        if deage {
            workingImage = try deageLocally(imageData: imageData, direction: deageDirection, workDir: workDir)
        }
        guard (try? workingImage.write(to: imageURL)) != nil else {
            throw OpenFaceAnalyzerError.failedToWriteImage
        }
        defer { try? FileManager.default.removeItem(at: workDir) }

        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = binDir
        process.arguments = [
            "-f", imageURL.path,
            "-out_dir", outDir.path,
            "-aus",
            "-pose",
            "-au_static",
            "-q"
        ]
        process.environment = processEnvironment()

        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw OpenFaceAnalyzerError.processFailed(
                errText?.isEmpty == false
                    ? errText!
                    : "OpenFace exited with status \(process.terminationStatus)."
            )
        }

        guard let csvURL = try FileManager.default.contentsOfDirectory(
            at: outDir,
            includingPropertiesForKeys: nil
        ).first(where: { $0.pathExtension.lowercased() == "csv" }) else {
            throw OpenFaceAnalyzerError.csvMissing
        }

        return try parseCSV(at: csvURL, imageData: workingImage)
    }

    private static func deageLocally(imageData: Data, direction: Int, workDir: URL) throws -> Data {
        let script = URL(fileURLWithPath: "/Users/bryanhan/painTest/scripts/deage_face.py")
        let input = workDir.appendingPathComponent("deage_in.jpg")
        let output = workDir.appendingPathComponent("deage_out.jpg")
        try imageData.write(to: input)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", script.path, input.path, output.path,
            "--direction", "\(direction)"
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: "/Users/bryanhan/painTest")
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let out = try? Data(contentsOf: output) else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw OpenFaceAnalyzerError.processFailed(
                err.isEmpty ? "FaceFusion de-age failed." : err
            )
        }
        return out
    }

    private static func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["OMP_NUM_THREADS"] = "1"
        env["VECLIB_MAXIMUM_THREADS"] = "1"
        let libPaths = [
            "/opt/homebrew/opt/opencv@4/lib",
            "/opt/homebrew/opt/openblas/lib",
            "/opt/homebrew/lib"
        ]
        let existing = env["DYLD_LIBRARY_PATH"] ?? ""
        env["DYLD_LIBRARY_PATH"] = (libPaths + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }
    #endif

    private static func analyzeWithLocalServer(
        imageData: Data,
        serverHost: String,
        deage: Bool,
        deageDirection: Int,
        targetAge: Int?,
        sourceAge: Int?,
        estimateAge: Bool
    ) async throws -> OpenFaceAnalysis {
        guard let url = analyzeURL(from: serverHost) else {
            throw OpenFaceAnalyzerError.missingServerHost
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = deage ? 300 : 180
        request.httpBody = imageData
        if deage {
            request.setValue("1", forHTTPHeaderField: "X-PainTest-Deage")
            request.setValue("\(deageDirection)", forHTTPHeaderField: "X-PainTest-Deage-Direction")
            if let targetAge {
                request.setValue("\(targetAge)", forHTTPHeaderField: "X-PainTest-Target-Age")
            }
            if let sourceAge {
                request.setValue("\(sourceAge)", forHTTPHeaderField: "X-PainTest-Source-Age")
            }
        }
        if estimateAge {
            request.setValue("1", forHTTPHeaderField: "X-PainTest-Estimate-Age")
        }
        let wantsJSON = deage || estimateAge
        if wantsJSON {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OpenFaceAnalyzerError.serverUnreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenFaceAnalyzerError.serverUnreachable("invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if [502, 503, 530].contains(http.statusCode) {
                throw OpenFaceAnalyzerError.serverUnreachable(
                    "tunnel offline (HTTP \(http.statusCode)). Re-run python3 scripts/openface_phone.py on your Mac and paste the new URL into Settings."
                )
            }
            throw OpenFaceAnalyzerError.processFailed(
                "OpenFace bridge returned HTTP \(http.statusCode)"
                    + (Self.shortErrorBody(data).isEmpty ? "." : ": \(Self.shortErrorBody(data))")
            )
        }

        if wantsJSON, let analysis = try? parseBridgeJSON(data, fallbackImage: imageData, requestedDeage: deage) {
            return analysis
        }
        // Older bridges answer with plain CSV even when JSON was requested.
        guard let csv = String(data: data, encoding: .utf8), csv.contains("confidence") else {
            throw OpenFaceAnalyzerError.processFailed("Could not parse the response from the bridge.")
        }
        return try parseCSVString(csv, imageData: imageData)
    }

    private struct BridgeResponse: Decodable {
        struct Age: Decodable {
            let age_low: Int
            let age_high: Int
            let age_estimate: Double
            let age_std: Double?

            var estimate: AgeEstimate {
                AgeEstimate(low: age_low, high: age_high, estimate: age_estimate, spread: age_std)
            }
        }

        let csv: String
        let image_base64: String?
        let deaged: Bool?
        let direction: Int?
        let target_age: Int?
        let age: Age?
        let deaged_age: Age?
        let deage_skipped: String?
        let original_csv: String?
        let passes: Int?
        let expression_drift: Double?
    }

    private static func parseBridgeJSON(_ data: Data, fallbackImage: Data, requestedDeage: Bool) throws -> OpenFaceAnalysis {
        let decoded = try JSONDecoder().decode(BridgeResponse.self, from: data)
        // When de-aged, `csv` is OpenFace on the de-aged image (this drives PSPI) and
        // `original_csv` is OpenFace on the real photo, kept as a comparison.
        var imageData = fallbackImage
        if let b64 = decoded.image_base64, let bytes = Data(base64Encoded: b64) {
            imageData = bytes
        }
        var analysis = try parseCSVString(decoded.csv, imageData: imageData)
        analysis.ageEstimate = decoded.age?.estimate
        let originalPSPI = decoded.original_csv
            .flatMap { try? parseCSVString($0, imageData: nil) }
            .flatMap { $0.outcome == .success ? $0.pspi : nil }

        if requestedDeage {
            analysis.deageInfo = DeageInfo(
                deaged: decoded.deaged ?? false,
                targetAge: decoded.target_age,
                directionYears: decoded.direction ?? 0,
                skipped: decoded.deage_skipped.flatMap(DeageInfo.SkipReason.init(rawValue:)),
                deagedAge: decoded.deaged_age?.estimate,
                originalPSPI: originalPSPI,
                passes: decoded.passes,
                expressionDrift: decoded.expression_drift
            )
        }
        return analysis
    }

    /// Accepts LAN IP, host:port, or full https://….trycloudflare.com URL.
    static func analyzeURL(from raw: String) -> URL? {
        endpointURL(from: raw, path: "/analyze")
    }

    static func deageURL(from raw: String) -> URL? {
        endpointURL(from: raw, path: "/deage")
    }

    static func healthURL(from raw: String) -> URL? {
        endpointURL(from: raw, path: "/health")
    }

    /// Quick reachability probe so a stale address fails in seconds instead of waiting out the analyze timeout.
    static func checkHealth(host: String, timeout: TimeInterval = 4) async -> Bool {
        guard let url = healthURL(from: host) else { return false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return false
            }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
        } catch {
            return false
        }
    }

    private static func endpointURL(from raw: String, path: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            var base = trimmed
            while base.hasSuffix("/") { base.removeLast() }
            return URL(string: base + path)
        }

        if trimmed.contains(":") {
            return URL(string: "http://\(trimmed)\(path)")
        }
        return URL(string: "http://\(trimmed):\(defaultPort)\(path)")
    }

    /// FaceFusion age preview only (no OpenFace).
    /// On-device FRAN is optional — it can jetsam on device; Mac bridge is the stable path.
    static func agePreview(
        imageData: Data,
        serverHost: String,
        direction: Int,
        preferOnDevice: Bool = false
    ) async throws -> Data {
        if preferOnDevice {
            do {
                return try await OnDeviceAgePreview.apply(imageData: imageData, direction: direction)
            } catch {
                // Fall through to Mac bridge when on-device isn't ready / fails.
            }
        }

        #if os(macOS)
        do {
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("painTest-deage-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }
            return try deageLocally(imageData: imageData, direction: direction, workDir: workDir)
        } catch {
            // Fall through to bridge.
        }
        #endif

        guard let url = deageURL(from: serverHost) else {
            throw OpenFaceAnalyzerError.missingServerHost
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("\(direction)", forHTTPHeaderField: "X-PainTest-Deage-Direction")
        request.timeoutInterval = 300
        request.httpBody = imageData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OpenFaceAnalyzerError.serverUnreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenFaceAnalyzerError.serverUnreachable("invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let shortBody = Self.shortErrorBody(data)
            if http.statusCode == 530 || http.statusCode == 502 || http.statusCode == 503 {
                throw OpenFaceAnalyzerError.serverUnreachable(
                    "tunnel offline (HTTP \(http.statusCode)). Re-run python3 scripts/openface_phone.py on your Mac and paste the new URL into Settings."
                )
            }
            throw OpenFaceAnalyzerError.processFailed(
                "Age preview failed (HTTP \(http.statusCode))"
                    + (shortBody.isEmpty ? "." : ": \(shortBody)")
            )
        }
        guard !data.isEmpty else {
            throw OpenFaceAnalyzerError.processFailed("Age preview returned an empty image.")
        }
        return data
    }

    private static func shortErrorBody(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return "" }
        // Strip HTML / Cloudflare noise
        if raw.localizedCaseInsensitiveContains("<html") || raw.localizedCaseInsensitiveContains("cloudflare") {
            return "origin unreachable"
        }
        return String(raw.prefix(160))
    }

    private static func parseCSV(at url: URL, imageData: Data) throws -> OpenFaceAnalysis {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parseCSVString(text, imageData: imageData)
    }

    private static func parseCSVString(_ text: String, imageData: Data?) throws -> OpenFaceAnalysis {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else { throw OpenFaceAnalyzerError.csvEmpty }

        let headers = splitCSVLine(lines[0])
        let row = splitCSVLine(lines[1])
        var values: [String: String] = [:]
        for (index, header) in headers.enumerated() where index < row.count {
            values[header] = row[index]
        }

        return OpenFaceAnalysis.fromCSVRow(values, imageData: imageData)
    }

    private static func splitCSVLine(_ line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func defaultOpenFaceRoot() -> URL {
        var candidates: [URL] = [
            URL(fileURLWithPath: "/Users/bryanhan/painTest/OpenFace")
        ]
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            candidates.insert(
                URL(fileURLWithPath: home).appendingPathComponent("painTest/OpenFace"),
                at: 0
            )
        }
        return candidates.first {
            FileManager.default.isExecutableFile(
                atPath: $0.appendingPathComponent("build/bin/FeatureExtraction").path
            )
        } ?? candidates[0]
    }
}
