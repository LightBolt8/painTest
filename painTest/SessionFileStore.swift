import Foundation

/// On-disk storage for analysis sessions: one JSON index plus a JPEG thumbnail per session.
enum SessionFileStore {
    private static let fileManager = FileManager.default
    private static let thumbnailCache = NSCache<NSUUID, NSData>()
    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    static var directory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensureDirectory(base.appendingPathComponent("Sessions", isDirectory: true))
    }

    private static var indexURL: URL {
        directory.appendingPathComponent("sessions.json")
    }

    private static var thumbnailsDirectory: URL {
        ensureDirectory(directory.appendingPathComponent("Thumbnails", isDirectory: true))
    }

    private static func thumbnailURL(for id: UUID) -> URL {
        thumbnailsDirectory.appendingPathComponent("\(id.uuidString).jpg")
    }

    private static func ensureDirectory(_ url: URL) -> URL {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func loadSessions() -> [AnalysisSession]? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        do {
            return try JSONDecoder().decode([AnalysisSession].self, from: data)
        } catch {
            print("Failed to decode sessions index:", error)
            return nil
        }
    }

    static func saveSessions(_ sessions: [AnalysisSession]) throws {
        let data = try JSONEncoder().encode(sessions)
        try data.write(to: indexURL, options: writeOptions)
    }

    static func saveThumbnail(_ data: Data, for id: UUID) {
        do {
            try data.write(to: thumbnailURL(for: id), options: writeOptions)
            thumbnailCache.setObject(data as NSData, forKey: id as NSUUID)
        } catch {
            print("Failed to save thumbnail:", error)
        }
    }

    static func thumbnail(for id: UUID) -> Data? {
        if let cached = thumbnailCache.object(forKey: id as NSUUID) {
            return cached as Data
        }
        guard let data = try? Data(contentsOf: thumbnailURL(for: id)) else { return nil }
        thumbnailCache.setObject(data as NSData, forKey: id as NSUUID)
        return data
    }

    static func deleteThumbnail(for id: UUID) {
        thumbnailCache.removeObject(forKey: id as NSUUID)
        try? fileManager.removeItem(at: thumbnailURL(for: id))
    }

    static func deleteAll() {
        thumbnailCache.removeAllObjects()
        try? fileManager.removeItem(at: directory)
    }
}
