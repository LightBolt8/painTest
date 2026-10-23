import Combine
import Foundation

@MainActor
final class PainStore: ObservableObject {
    @Published private(set) var entries: [PainEntry] = []
    @Published private(set) var sessions: [AnalysisSession] = []

    private let storageKey = "paintest_entries_v1"
    /// Pre-file-storage location; migrated into `SessionFileStore` on first launch, then removed.
    private let legacySessionsKey = "paintest_sessions_v1"

    init() {
        load()
    }

    // MARK: - Manual pain entries (legacy)

    func addEntry(date: Date, value: Double, notes: String) {
        let entry = PainEntry(date: date, value: value, notes: notes)
        AppAnimations.run {
            entries.append(entry)
            entries.sort { $0.date < $1.date }
        }
        saveEntries()
    }

    func deleteEntry(_ entry: PainEntry) {
        AppAnimations.run {
            entries.removeAll { $0.id == entry.id }
        }
        saveEntries()
    }

    // MARK: - Analysis sessions

    @discardableResult
    func addSession(analysis: OpenFaceAnalysis, agedBeforeAnalysis: Bool) -> AnalysisSession {
        let session = AnalysisSession(analysis: analysis, agedBeforeAnalysis: agedBeforeAnalysis)
        if let thumbnail = AnalysisSession.makeThumbnail(from: analysis.sourceImageData) {
            SessionFileStore.saveThumbnail(thumbnail, for: session.id)
        }
        AppAnimations.run {
            sessions.append(session)
            sessions.sort { $0.date < $1.date }
        }
        saveSessions()
        return session
    }

    func session(withID id: UUID) -> AnalysisSession? {
        sessions.first { $0.id == id }
    }

    func updateSelfReport(sessionID: UUID, pain: Int?, notes: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        guard sessions[index].selfReportedPain != pain || sessions[index].notes != notes else { return }
        sessions[index].selfReportedPain = pain
        sessions[index].notes = notes
        saveSessions()
    }

    func deleteSession(_ session: AnalysisSession) {
        AppAnimations.run {
            sessions.removeAll { $0.id == session.id }
        }
        SessionFileStore.deleteThumbnail(for: session.id)
        saveSessions()
    }

    func clearAll() {
        AppAnimations.run {
            entries = []
            sessions = []
        }
        saveEntries()
        SessionFileStore.deleteAll()
        UserDefaults.standard.removeObject(forKey: legacySessionsKey)
        LastCaptureStore.clear()
        NeutralBaselineStore.shared.clear()
    }

    // MARK: - Derived helpers

    var latest: PainEntry? {
        entries.sortedDescending().first
    }

    var previous: PainEntry? {
        let sorted = entries.sortedDescending()
        return sorted.count > 1 ? sorted[1] : nil
    }

    var recent: [PainEntry] {
        Array(entries.sortedDescending().prefix(5))
    }

    var latestSession: AnalysisSession? {
        sessions.sorted { $0.date > $1.date }.first
    }

    struct MonthlyGroup: Identifiable {
        let id = UUID()
        let monthStart: Date
        let entries: [PainEntry]
        let average: Double?
    }

    var monthlyGroups: [MonthlyGroup] {
        let calendar = Calendar.current

        let grouped = Dictionary(grouping: entries.sortedDescending()) { (entry: PainEntry) in
            calendar.date(from: calendar.dateComponents([.year, .month], from: entry.date)) ?? entry.date
        }

        return grouped
            .map { (monthStart, monthEntries) in
                let avg: Double? = monthEntries.isEmpty
                    ? nil
                    : monthEntries.map(\.value).reduce(0, +) / Double(monthEntries.count)
                return MonthlyGroup(
                    monthStart: monthStart,
                    entries: monthEntries.sortedDescending(),
                    average: avg
                )
            }
            .sorted { $0.monthStart > $1.monthStart }
    }

    struct SessionMonthGroup: Identifiable {
        let id: Date
        let monthStart: Date
        let sessions: [AnalysisSession]
        let averagePSPI: Double?
    }

    var sessionMonthlyGroups: [SessionMonthGroup] {
        let calendar = Calendar.current
        let sorted = sessions.sorted { $0.date > $1.date }
        let grouped = Dictionary(grouping: sorted) { session -> Date in
            calendar.date(from: calendar.dateComponents([.year, .month], from: session.date)) ?? session.date
        }

        return grouped
            .map { monthStart, monthSessions in
                let success = monthSessions.filter(\.faceFound)
                let avg: Double? = success.isEmpty
                    ? nil
                    : success.map(\.pspi).reduce(0, +) / Double(success.count)
                return SessionMonthGroup(
                    id: monthStart,
                    monthStart: monthStart,
                    sessions: monthSessions,
                    averagePSPI: avg
                )
            }
            .sorted { $0.monthStart > $1.monthStart }
    }

    enum TrendRange: CaseIterable, Identifiable {
        case oneMonth
        case threeMonths
        case sixMonths
        case oneYear
        case all

        var id: Self { self }

        var title: String {
            switch self {
            case .oneMonth: return "1m"
            case .threeMonths: return "3m"
            case .sixMonths: return "6m"
            case .oneYear: return "1y"
            case .all: return "All"
            }
        }

        var days: Int? {
            switch self {
            case .oneMonth: return 30
            case .threeMonths: return 90
            case .sixMonths: return 180
            case .oneYear: return 365
            case .all: return nil
            }
        }
    }

    func entries(in range: TrendRange) -> [PainEntry] {
        guard let days = range.days else {
            return entries.sortedAscending()
        }
        let calendar = Calendar.current
        guard let from = calendar.date(byAdding: .day, value: -days, to: Date()) else {
            return entries.sortedAscending()
        }
        return entries
            .filter { $0.date >= from }
            .sortedAscending()
    }

    struct TrendFilter: Equatable {
        var includeAged = false
        var includeLowConfidence = false

        func admits(_ session: AnalysisSession) -> Bool {
            guard session.faceFound else { return false }
            if session.agedBeforeAnalysis && !includeAged { return false }
            if !session.passedStrictChecks && !includeLowConfidence { return false }
            return true
        }
    }

    /// Successful face captures with PSPI, for Trends.
    func sessions(in range: TrendRange, filter: TrendFilter) -> [AnalysisSession] {
        let success = sessions.filter(filter.admits)
        guard let days = range.days else {
            return success.sorted { $0.date < $1.date }
        }
        let calendar = Calendar.current
        guard let from = calendar.date(byAdding: .day, value: -days, to: Date()) else {
            return success.sorted { $0.date < $1.date }
        }
        return success
            .filter { $0.date >= from }
            .sorted { $0.date < $1.date }
    }

    struct Stats {
        let min: Double
        let max: Double
        let avg: Double
        let count: Int
        let first: PainEntry
        let last: PainEntry
        let change: Double
    }

    func stats(for range: TrendRange) -> Stats? {
        let data = entries(in: range)
        guard !data.isEmpty else { return nil }
        let values = data.map(\.value)
        guard let minVal = values.min(), let maxVal = values.max() else { return nil }
        let avg = values.reduce(0, +) / Double(values.count)
        guard let first = data.first, let last = data.last else { return nil }
        let change = last.value - first.value
        return Stats(
            min: minVal,
            max: maxVal,
            avg: avg,
            count: data.count,
            first: first,
            last: last,
            change: change
        )
    }

    struct SessionStats {
        let min: Double
        let max: Double
        let avg: Double
        let count: Int
        let firstDate: Date
        let lastDate: Date
        let change: Double
    }

    func sessionStats(for range: TrendRange, filter: TrendFilter) -> SessionStats? {
        let data = sessions(in: range, filter: filter)
        guard !data.isEmpty else { return nil }
        let values = data.map(\.pspi)
        guard let minVal = values.min(), let maxVal = values.max() else { return nil }
        let avg = values.reduce(0, +) / Double(values.count)
        guard let first = data.first, let last = data.last else { return nil }
        return SessionStats(
            min: minVal,
            max: maxVal,
            avg: avg,
            count: data.count,
            firstDate: first.date,
            lastDate: last.date,
            change: last.pspi - first.pspi
        )
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            do {
                entries = try JSONDecoder().decode([PainEntry].self, from: data)
                    .sorted { $0.date < $1.date }
            } catch {
                print("Failed to load pain entries:", error)
            }
        }
        if let stored = SessionFileStore.loadSessions() {
            sessions = stored.sorted { $0.date < $1.date }
        }
        migrateLegacySessionsIfNeeded()
    }

    private func migrateLegacySessionsIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: legacySessionsKey) else { return }
        do {
            var legacy = try JSONDecoder().decode([AnalysisSession].self, from: data)
            let existingIDs = Set(sessions.map(\.id))
            for index in legacy.indices {
                if let thumbnail = legacy[index].legacyThumbnailJPEG {
                    SessionFileStore.saveThumbnail(thumbnail, for: legacy[index].id)
                }
                legacy[index].clearLegacyThumbnail()
            }
            sessions = (sessions + legacy.filter { !existingIDs.contains($0.id) })
                .sorted { $0.date < $1.date }
            try SessionFileStore.saveSessions(sessions)
            UserDefaults.standard.removeObject(forKey: legacySessionsKey)
        } catch {
            print("Failed to migrate legacy sessions:", error)
        }
    }

    private func saveEntries() {
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            print("Failed to save pain entries:", error)
        }
    }

    private func saveSessions() {
        do {
            try SessionFileStore.saveSessions(sessions)
        } catch {
            print("Failed to save analysis sessions:", error)
        }
    }
}
